#if os(macOS)
import Foundation

public struct CodexAppServerNotification: Sendable, Equatable {
    public let method: String
    public let params: JSONValue?

    public init(method: String, params: JSONValue?) {
        self.method = method
        self.params = params
    }
}

/// A long-lived JSON-RPC client for `codex app-server`.
///
/// Framing assumption: every JSON-RPC message is a single line of JSON
/// terminated by `\n` on both stdin and stdout, matching the raw
/// `{"method":"account/rateLimits/read","id":1}` examples Codex documents.
/// If a future Codex release switches to `Content-Length`-framed messages
/// (LSP style), only `write(_:)` and `consume(data:)` need to change.
///
/// All mutable state is only ever touched on `queue`, which is what makes
/// this class safe to share across concurrent callers despite being a plain
/// class rather than an actor.
public final class CodexAppServerClient: @unchecked Sendable {
    private typealias Completion = (Result<JSONValue, Error>) -> Void

    private struct DeferredRequest {
        let method: String
        let params: JSONValue?
        let timeout: TimeInterval
        let completion: Completion
    }

    private let executablePath: String?
    private let queue = DispatchQueue(label: "quotapulse.codex-app-server")

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var buffer = Data()
    private var stderrTail = Data()
    private var nextRequestID = 1
    private var pending: [Int: Completion] = [:]
    private var deferredRequests: [DeferredRequest] = []
    private var isReady = false
    private var notificationContinuations: [UUID: AsyncStream<CodexAppServerNotification>.Continuation] = [:]

    /// - Parameter executablePath: overrides the resolved path to the
    ///   `codex` binary. Intended for tests; production callers should use
    ///   the default, which searches common install locations and `PATH`.
    public init(executablePath: String? = nil) {
        self.executablePath = executablePath
    }

    deinit {
        process?.terminate()
    }

    public func stop() {
        queue.async { [self] in
            // `terminateLocked` below calls `process.terminate()`, which only
            // *requests* termination — the process is generally still alive
            // when this line runs, and `Process.terminationStatus` raises an
            // NSException if read before the process has actually exited.
            // -1 is a synthetic status marking "stopped by us", distinct from
            // the real exit status `terminationHandler` reports when the
            // process exits on its own.
            terminateLocked(with: .appServerExited(-1))
        }
    }

    /// Server-initiated JSON-RPC notifications. The stream is independent
    /// from request/response traffic and remains active across app-server
    /// restarts.
    public func notifications() -> AsyncStream<CodexAppServerNotification> {
        let identifier = UUID()
        return AsyncStream { continuation in
            queue.async { [weak self] in
                self?.notificationContinuations[identifier] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.queue.async {
                    self?.notificationContinuations.removeValue(forKey: identifier)
                }
            }
        }
    }

    public func request(
        method: String,
        params: JSONValue? = nil,
        timeout: TimeInterval = 15
    ) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                var didResume = false
                let resumeOnce: Completion = { result in
                    guard !didResume else { return }
                    didResume = true
                    switch result {
                    case .success(let value): continuation.resume(returning: value)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }

                do {
                    try ensureStartedLocked()
                } catch {
                    resumeOnce(.failure(error))
                    return
                }

                let request = DeferredRequest(
                    method: method,
                    params: params,
                    timeout: timeout,
                    completion: resumeOnce
                )
                if isReady {
                    sendRequestLocked(request)
                } else {
                    deferredRequests.append(request)
                }
            }
        }
    }

    // MARK: - Process management (all methods below assume `queue`)

    private func ensureStartedLocked() throws {
        guard process == nil else { return }

        guard let path = executablePath ?? Self.resolveExecutablePath() else {
            throw QuotaError.executableNotFound("codex")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["app-server"]
        process.environment = Self.childEnvironment(executablePath: path)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.terminationHandler = { [weak self] proc in
            self?.queue.async {
                self?.terminateLocked(with: .appServerExited(proc.terminationStatus))
            }
        }

        do {
            try process.run()
        } catch {
            throw QuotaError.appServerLaunchFailed(error.localizedDescription)
        }

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        self.stderrHandle = stderrPipe.fileHandleForReading
        self.isReady = false

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async {
                self?.consumeLocked(data: data)
            }
        }

        // Always drain stderr. A long-lived child process can otherwise block
        // forever once its pipe buffer fills.
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async {
                self?.appendStderrLocked(data)
            }
        }

        do {
            try sendInitializeLocked()
        } catch {
            terminateLocked(with: .appServerLaunchFailed(error.localizedDescription))
            throw error
        }
    }

    private func sendInitializeLocked() throws {
        let request = DeferredRequest(
            method: "initialize",
            params: .object([
                "clientInfo": .object([
                    "name": .string("quota-pulse"),
                    "version": .string("1.0"),
                ]),
            ]),
            timeout: 10,
            completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    do {
                        try self.writeNotificationLocked(method: "initialized")
                        self.isReady = true
                        self.flushDeferredRequestsLocked()
                    } catch {
                        self.terminateLocked(
                            with: .appServerLaunchFailed(error.localizedDescription)
                        )
                    }
                case .failure(let error):
                    self.terminateLocked(with: Self.quotaError(from: error))
                }
            }
        )
        sendRequestLocked(request)
    }

    private func terminateLocked(with error: QuotaError) {
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        isReady = false
        buffer.removeAll()
        stderrTail.removeAll()

        let stalePending = pending
        pending.removeAll()
        for resume in stalePending.values {
            resume(.failure(error))
        }

        let staleDeferred = deferredRequests
        deferredRequests.removeAll()
        for request in staleDeferred {
            request.completion(.failure(error))
        }
    }

    private func consumeLocked(data: Data) {
        buffer.append(data)
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newlineIndex]
            buffer.removeSubrange(...newlineIndex)
            guard !lineData.isEmpty else { continue }
            handleLineLocked(Data(lineData))
        }
    }

    private func handleLineLocked(_ lineData: Data) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: lineData),
              case .object(let object) = value
        else {
            return
        }

        guard let id = object["id"]?.intValue else {
            if let method = object["method"]?.stringValue {
                let notification = CodexAppServerNotification(
                    method: method,
                    params: object["params"]
                )
                for continuation in notificationContinuations.values {
                    continuation.yield(notification)
                }
            }
            return
        }

        guard let completion = pending.removeValue(forKey: id) else {
            return
        }

        if let error = object["error"] {
            let message = error["message"]?.stringValue ?? "unknown error"
            completion(.failure(QuotaError.invalidResponse(message)))
        } else {
            completion(.success(object["result"] ?? .null))
        }
    }

    private func sendRequestLocked(_ request: DeferredRequest) {
        let id = nextRequestID
        nextRequestID += 1
        pending[id] = request.completion

        queue.asyncAfter(deadline: .now() + request.timeout) { [weak self] in
            guard let self, let completion = self.pending.removeValue(forKey: id) else {
                return
            }
            completion(.failure(QuotaError.requestTimedOut))
            self.terminateLocked(with: .requestTimedOut)
        }

        var object: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(request.method),
        ]
        if let params = request.params {
            object["params"] = params
        }

        do {
            try writeLocked(.object(object))
        } catch {
            pending.removeValue(forKey: id)
            request.completion(.failure(error))
            terminateLocked(with: Self.quotaError(from: error))
        }
    }

    private func writeNotificationLocked(method: String, params: JSONValue? = nil) throws {
        var object: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let params {
            object["params"] = params
        }
        try writeLocked(.object(object))
    }

    private func flushDeferredRequestsLocked() {
        let requests = deferredRequests
        deferredRequests.removeAll()
        for request in requests {
            guard isReady else {
                request.completion(.failure(QuotaError.appServerExited(-1)))
                continue
            }
            sendRequestLocked(request)
        }
    }

    private func appendStderrLocked(_ data: Data) {
        stderrTail.append(data)
        let maximumSize = 8 * 1024
        if stderrTail.count > maximumSize {
            stderrTail.removeFirst(stderrTail.count - maximumSize)
        }
    }

    private func writeLocked(_ value: JSONValue) throws {
        guard let stdinHandle else {
            throw QuotaError.appServerLaunchFailed("stdin is not available")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        try stdinHandle.write(contentsOf: data)
    }

    private static func quotaError(from error: Error) -> QuotaError {
        if let quotaError = error as? QuotaError {
            return quotaError
        }
        return .appServerLaunchFailed(error.localizedDescription)
    }

    static func sanitizedChildEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = environment
        environment.removeValue(forKey: "QUOTAPULSE_CLAUDE_OAUTH_TOKEN")
        environment.removeValue(forKey: "CLAUDE_CODE_OAUTH_TOKEN")
        return environment
    }

    /// The environment `codex app-server` is launched with.
    ///
    /// The inherited `PATH` cannot be passed through unchanged. `npm install
    /// -g @openai/codex` installs a `#!/usr/bin/env node` launcher rather than
    /// a native binary, so the child needs `node` on its `PATH` — and a GUI
    /// app inherits launchd's `PATH`, which has no `node` in it. Prepending
    /// the directories the locator searches (the resolved binary's own
    /// directory first, since that is where the matching `node` usually lives)
    /// makes the launcher work regardless of how Codex was installed.
    static func childEnvironment(
        executablePath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        searchDirectories: [String] = ExecutableLocator.default.searchDirectories()
    ) -> [String: String] {
        var environment = sanitizedChildEnvironment(environment)

        let inherited = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let ordered = [URL(fileURLWithPath: executablePath).deletingLastPathComponent().path]
            + searchDirectories
            + inherited
            // Keep the system directories reachable even if everything above
            // was empty: `/usr/bin/env` looks up `node` on this `PATH`.
            + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

        var seen = Set<String>()
        environment["PATH"] = ordered
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
        return environment
    }

    /// The `codex` binary this client would launch, or `nil` when it is not
    /// installed anywhere we can see. Public so the app can tell the user
    /// "Codex is not installed" up front, instead of only after a launch
    /// failure.
    ///
    /// - Parameter allowLoginShell: pass `false` from the main thread; see
    ///   `ExecutableLocator.locate(_:allowLoginShell:)`.
    public static func resolveExecutablePath(allowLoginShell: Bool = true) -> String? {
        ExecutableLocator.default.locate("codex", allowLoginShell: allowLoginShell)
    }
}
#endif
