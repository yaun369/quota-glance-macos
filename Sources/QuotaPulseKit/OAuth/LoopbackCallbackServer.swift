import Foundation
import Network

public enum LoopbackCallbackServerError: LocalizedError, Sendable, Equatable {
    case portUnavailable(UInt16)
    case notStarted
    case timedOut
    case cancelled
    case invalidRequest(String)

    public var errorDescription: String? {
        switch self {
        case .portUnavailable(let port):
            return port == 0
                ? QuotaL10n.string("login.portUnavailable", "Could not listen on the sign-in callback port on this machine.")
                : QuotaL10n.string("login.portBusy", "Port \(String(port)) is already in use. Close whatever is using it and try again.")
        case .notStarted:
            return QuotaL10n.string("login.serverNotRunning", "The local callback server has not started.")
        case .timedOut:
            return QuotaL10n.string("login.timedOut", "Timed out waiting for sign-in authorization. Please try again.")
        case .cancelled:
            return QuotaL10n.string("login.cancelled", "Sign-in cancelled.")
        case .invalidRequest(let reason):
            return QuotaL10n.string("login.badCallback", "Received an unrecognized callback request: \(reason)")
        }
    }
}

/// A single-shot local HTTP listener for the redirect leg of an
/// authorization-code + PKCE flow. Binds to `127.0.0.1` only (never `0.0.0.0`
/// or any external interface), accepts the browser's GET redirect, extracts
/// its query string, replies with a static "you can close this tab" page,
/// then shuts the socket down. There is never a second real request to
/// answer, since the authorize page redirects exactly once — the one
/// exception handled here is a browser probing `/favicon.ico` on a separate
/// connection, which gets a 404 without ending the wait.
///
/// One instance serves exactly one login attempt. Create a new instance
/// (and a new `PKCESession`) for each attempt.
public final class LoopbackCallbackServer: @unchecked Sendable {
    private let requestedPort: UInt16?
    private let callbackPath: String
    private let queue = DispatchQueue(label: "quotapulse.oauth.loopback")

    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private var resultContinuation: CheckedContinuation<[String: String], Error>?
    private var pendingResult: Result<[String: String], Error>?
    private var timeoutTimer: DispatchSourceTimer?
    private var hasStarted = false
    private var isFinished = false
    private var startDidResume = false

    /// - Parameters:
    ///   - port: `nil` picks an ephemeral port (Claude's flow, which accepts
    ///     any loopback redirect URI); a fixed value pins the listener to
    ///     that port (Codex's flow, whose registered redirect URI is
    ///     `http://localhost:1455/...`).
    ///   - callbackPath: the path component of the redirect URI. Requests to
    ///     any other path get a 404 and do not count as the callback.
    public init(port: UInt16? = nil, callbackPath: String = "/callback") {
        self.requestedPort = port
        self.callbackPath = callbackPath
    }

    /// `deinit` can run on whatever thread happens to drop the last strong
    /// reference — never a guaranteed match for `queue`, which every other
    /// read or write of `listener`/`activeConnection` goes through. Calling
    /// `.cancel()` on them directly here would race those in-flight
    /// callbacks on `queue`. Capturing the two locally and dispatching their
    /// cancellation *onto* `queue` (without capturing `self`, which is mid
    /// teardown) keeps this instance's very last bit of cleanup ordered with
    /// everything else instead of racing it.
    deinit {
        let listener = self.listener
        let activeConnection = self.activeConnection
        queue.async {
            listener?.cancel()
            activeConnection?.cancel()
        }
    }

    /// Binds the listener and returns the port it ended up listening on
    /// (equal to `port` when one was requested). Must be called before
    /// `waitForCallback(timeout:)`.
    @discardableResult
    public func start() async throws -> UInt16 {
        let nwPort: NWEndpoint.Port
        if let requestedPort {
            guard let port = NWEndpoint.Port(rawValue: requestedPort) else {
                throw LoopbackCallbackServerError.portUnavailable(requestedPort)
            }
            nwPort = port
        } else {
            nwPort = .any
        }

        let params = NWParameters.tcp
        // Deliberately does *not* set `allowLocalEndpointReuse`: a bind
        // conflict on Codex's fixed port 1455 (e.g. another QuotaPulse
        // instance, or `codex login` itself already listening) must fail
        // loudly here so the login UI can detect it and offer a retry,
        // rather than two listeners silently sharing the port.
        // The endpoint carries both the loopback host and the port (`.any`
        // meaning ephemeral). Do NOT also pass `on: nwPort` to `NWListener` —
        // supplying the port twice makes Network.framework reject the
        // listener with "Local endpoint has port set, cannot override",
        // which used to surface here as a bogus "port occupied" error.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            throw LoopbackCallbackServerError.portUnavailable(requestedPort ?? 0)
        }

        startDidResume = false
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.startDidResume else { return }
                switch state {
                case .ready:
                    self.startDidResume = true
                    guard let port = listener.port?.rawValue else {
                        continuation.resume(throwing: LoopbackCallbackServerError.portUnavailable(self.requestedPort ?? 0))
                        return
                    }
                    self.listener = listener
                    self.hasStarted = true
                    continuation.resume(returning: port)
                case .failed:
                    self.startDidResume = true
                    listener.cancel()
                    continuation.resume(throwing: LoopbackCallbackServerError.portUnavailable(self.requestedPort ?? 0))
                case .cancelled:
                    self.startDidResume = true
                    continuation.resume(throwing: LoopbackCallbackServerError.cancelled)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    /// Suspends until the browser's redirect delivers a query string, the
    /// timeout elapses, `cancel()` is called, or the calling `Task` itself
    /// is cancelled (e.g. a "Cancel" button abandoning the enclosing login
    /// flow) — all four tear down the same way, so a caller cancelling its
    /// own `Task` doesn't leave this listener bound in the background for
    /// the rest of `timeout`. Safe to call any time after `start()` returns
    /// — if the callback already arrived first, the buffered result is
    /// returned immediately.
    public func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: LoopbackCallbackServerError.cancelled)
                        return
                    }
                    guard self.hasStarted else {
                        continuation.resume(throwing: LoopbackCallbackServerError.notStarted)
                        return
                    }
                    if let pending = self.pendingResult {
                        self.pendingResult = nil
                        continuation.resume(with: pending)
                        return
                    }
                    guard !self.isFinished else {
                        continuation.resume(throwing: LoopbackCallbackServerError.cancelled)
                        return
                    }

                    self.resultContinuation = continuation
                    let timer = DispatchSource.makeTimerSource(queue: self.queue)
                    timer.schedule(deadline: .now() + timeout)
                    timer.setEventHandler { [weak self] in
                        self?.finish(.failure(LoopbackCallbackServerError.timedOut))
                    }
                    timer.resume()
                    self.timeoutTimer = timer
                }
            }
        } onCancel: {
            // Runs synchronously, possibly before `operation` above has even
            // registered its continuation (Task cancelled the instant it was
            // created) — `finish` already handles that ordering by buffering
            // into `pendingResult`, which the `guard let pending` branch
            // above then picks straight up.
            cancel()
        }
    }

    public func cancel() {
        queue.async { [weak self] in
            self?.finish(.failure(LoopbackCallbackServerError.cancelled))
        }
    }

    // MARK: - Connection handling (all on `queue`)

    private func accept(_ connection: NWConnection) {
        queue.async { [weak self] in
            guard let self, !self.isFinished, self.activeConnection == nil else {
                connection.cancel()
                return
            }
            self.activeConnection = connection
            connection.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    self?.queue.async {
                        guard let self, self.activeConnection === connection else { return }
                        self.activeConnection = nil
                    }
                }
            }
            connection.start(queue: self.queue)
            self.receive(on: connection, buffer: Data())
        }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                guard self.activeConnection === connection else { return }

                var buffer = buffer
                if let data { buffer.append(data) }

                if let requestLine = Self.extractRequestLine(from: buffer) {
                    self.handle(requestLine: requestLine, connection: connection)
                    return
                }
                if isComplete || error != nil {
                    self.activeConnection = nil
                    connection.cancel()
                    return
                }
                guard buffer.count <= 16_384 else {
                    self.activeConnection = nil
                    connection.cancel()
                    return
                }
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func handle(requestLine: String, connection: NWConnection) {
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: "http://127.0.0.1\(parts[1])") else {
            respond(status: "400 Bad Request", body: Self.errorPage, on: connection)
            activeConnection = nil
            return
        }

        guard components.path == callbackPath else {
            // Not the redirect — most commonly a browser's automatic
            // favicon probe on a second connection. Answer it and keep
            // listening for the real callback instead of failing outright.
            respond(status: "404 Not Found", body: Self.errorPage, on: connection)
            activeConnection = nil
            return
        }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }

        respond(status: "200 OK", body: Self.successPage, on: connection)
        // `respond` above only *schedules* the send; the connection isn't
        // actually closed until its own completion handler runs once the
        // bytes are flushed. `finish` below unconditionally cancels
        // `activeConnection` for its other callers (timeout, explicit
        // `cancel()`), so it must not find this connection still assigned —
        // otherwise it would cancel the socket out from under the in-flight
        // send and the browser would see a reset connection instead of the
        // success page.
        activeConnection = nil
        finish(.success(query))
    }

    private func respond(status: String, body: String, on connection: NWConnection) {
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Connection: close\r\n\r\n"
        var responseData = Data(head.utf8)
        responseData.append(bodyData)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard !isFinished else { return }
        isFinished = true
        timeoutTimer?.cancel()
        timeoutTimer = nil
        activeConnection?.cancel()
        activeConnection = nil
        listener?.cancel()
        listener = nil

        if let continuation = resultContinuation {
            resultContinuation = nil
            continuation.resume(with: result)
        } else {
            pendingResult = result
        }
    }

    private static func extractRequestLine(from buffer: Data) -> String? {
        guard let range = buffer.range(of: Data("\r\n".utf8)) else { return nil }
        return String(data: buffer[..<range.lowerBound], encoding: .utf8)
    }

    /// The two pages the browser lands on after the OAuth round trip. They
    /// are the one piece of UI this kit renders itself, and they are read in
    /// a browser rather than in the app — so they follow the app's language,
    /// not the browser's, which is what `QuotaL10n` resolves.
    private static var successPage: String {
        page(
            title: QuotaL10n.string("login.page.success.title", "Signed in"),
            body: QuotaL10n.string(
                "login.page.success.body",
                "You can close this page and go back to QuotaGlance."
            )
        )
    }

    private static var errorPage: String {
        page(
            title: QuotaL10n.string("login.page.failure.title", "Sign-in failed"),
            body: QuotaL10n.string("login.page.failure.body", "Please go back to QuotaGlance and try again.")
        )
    }

    private static func page(title: String, body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title></head>
        <body style="font-family:-apple-system,sans-serif;text-align:center;padding-top:80px;">
        <h2>\(title)</h2><p>\(body)</p>
        </body></html>
        """
    }
}
