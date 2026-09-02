#if canImport(WatchConnectivity)
import Foundation
import WatchConnectivity

@MainActor
public protocol QuotaConnectivityReceiving: AnyObject {
    func quotaConnectivitySession(_ session: QuotaConnectivitySession, didReceive payload: QuotaConnectivityPayload)
}

@MainActor
public protocol QuotaConnectivityPayloadProviding: AnyObject {
    func latestQuotaConnectivityPayload() -> QuotaConnectivityPayload?
}

/// 手表把「我这块表上装了哪些常驻位」报回 iPhone。
///
/// 反方向的一条独立通道，而不是塞进 `QuotaConnectivityPayload`：那个 payload
/// 是 iPhone -> Watch 的额度数据，两者的方向、频率和生命周期都不一样，混在一起
/// 会让「手表报告」变成额度推送的搭车乘客，额度不更新时它就发不出去。
@MainActor
public protocol QuotaSurfaceReportReceiving: AnyObject {
    func quotaConnectivitySession(
        _ session: QuotaConnectivitySession,
        didReceiveSurfaceReport surfaces: Set<PersistentSurface>
    )
}

/// Thin wrapper around `WCSession` used by both the iPhone app and Watch app.
/// `updateApplicationContext` remains the durable latest-state channel. A
/// small request/reply message complements it on cold launch so a reachable
/// iPhone can immediately provide its cache before a new context exists.
@MainActor
public final class QuotaConnectivitySession: NSObject {
    public static let shared = QuotaConnectivitySession()

    public weak var receiver: QuotaConnectivityReceiving?
    public weak var payloadProvider: QuotaConnectivityPayloadProviding?
    public weak var surfaceReceiver: QuotaSurfaceReportReceiving?

    private let payloadKey = "quotaPayload"
    private let surfaceReportKey = "quotaSurfaceReport"
    private let requestLatestPayloadKey = "requestLatestQuotaPayload"
    private var pendingContextData: Data?
    private var shouldRequestLatestPayload = false
    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    override private init() {
        super.init()
    }

    public func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    /// Reads whatever context was last delivered, in case it arrived before
    /// `activate()` finished wiring up the delegate — e.g. the Watch app
    /// cold-launching with a snapshot already waiting for it.
    public func consumeLastReceivedContext() {
        guard let session else { return }
        let context = session.receivedApplicationContext
        if let data = context[payloadKey] as? Data {
            decode(data)
        }
        decodeSurfaceReport(context)
    }

    /// Asks a currently reachable companion for its cached latest snapshot.
    /// This is especially important in the Watch simulator, which doesn't
    /// inherit the paired iPhone simulator's iCloud account.
    public func requestLatestPayload() {
        guard let session else { return }
        guard session.activationState == .activated else {
            shouldRequestLatestPayload = true
            activate()
            return
        }
        guard session.isReachable else {
            shouldRequestLatestPayload = true
            return
        }

        shouldRequestLatestPayload = false
        session.sendMessage(
            [requestLatestPayloadKey: true],
            replyHandler: { [weak self] reply in
                guard let data = reply[self?.payloadKey ?? ""] as? Data else { return }
                Task { @MainActor in
                    self?.decode(data)
                }
            },
            errorHandler: { [weak self] _ in
                Task { @MainActor in
                    self?.shouldRequestLatestPayload = true
                }
            }
        )
    }

    public func send(_ payload: QuotaConnectivityPayload) throws {
        let data = try JSONEncoder.quotaPulse.encode(payload)
        guard let session else { return }
        guard session.activationState == .activated else {
            // `updateApplicationContext` is only legal after activation. Keep
            // the newest payload so a fast cache/CloudKit read during launch
            // isn't silently lost while WCSession is still activating.
            pendingContextData = data
            activate()
            return
        }
        try session.updateApplicationContext([payloadKey: data])
        pendingContextData = nil
    }

    #if os(watchOS)
    /// 把这块表上已添加的复杂功能报给 iPhone。
    ///
    /// 手表这一侧从不调用 `send(_:)`（额度是单向推过来的），所以它的 outgoing
    /// application context 完全属于这条报告，不会和额度 payload 抢同一个字典。
    ///
    /// 空集合也照发：一次「我这儿一个都没有」的报告，和一次「我加了一个」的
    /// 报告同样是信息——只是 iPhone 那侧的里程碑是闩锁的，不会因此撤销。
    public func reportInstalledSurfaces(_ surfaces: Set<PersistentSurface>) {
        guard let session, session.activationState == .activated else { return }
        try? session.updateApplicationContext([surfaceReportKey: surfaces.map(\.rawValue).sorted()])
    }
    #endif

    #if os(iOS)
    /// 这台 iPhone 到底有没有配对的 Apple Watch，以及表上装没装码量。
    ///
    /// 引导分支的事实依据（issue：不要给没有 Watch 的用户「添加表盘复杂功能」）。
    /// `WCSession` 没被支持时两个都是 `false`——那种情况下这台设备上不可能有表。
    /// 激活完成前这两个属性没有定义好的值，所以未激活时一律答「没有」。
    /// 代价是启动最初的一瞬间引导会少列一条；调用方（引导页）在回到前台时
    /// 会重新问一次，那时一定已经激活完了。
    public var pairedWatch: (isPaired: Bool, isAppInstalled: Bool) {
        guard let session, session.activationState == .activated else { return (false, false) }
        return (session.isPaired, session.isWatchAppInstalled)
    }
    #endif

    private func flushPendingContext() {
        guard
            let session,
            session.activationState == .activated,
            let pendingContextData
        else { return }

        do {
            try session.updateApplicationContext([payloadKey: pendingContextData])
            self.pendingContextData = nil
        } catch {
            // Keep the newest payload for a later activation instead of
            // dropping it during a transient WatchConnectivity failure.
        }
    }

    /// 常驻位报告走原始字符串数组而不是 JSON `Data`：它是一个纯清单，
    /// application context 本来就接受 plist 类型，多一层编解码只会多一处失败点。
    private func decodeSurfaceReport(_ context: [String: Any]) {
        guard let raw = context[surfaceReportKey] as? [String] else { return }
        let surfaces = Set(raw.compactMap(PersistentSurface.init(rawValue:)))
        guard !surfaces.isEmpty else { return }
        surfaceReceiver?.quotaConnectivitySession(self, didReceiveSurfaceReport: surfaces)
    }

    private func decode(_ data: Data) {
        guard let payload = try? JSONDecoder.quotaPulse.decode(QuotaConnectivityPayload.self, from: data) else { return }
        receiver?.quotaConnectivitySession(self, didReceive: payload)
    }

    private func latestPayloadData(for session: WCSession) -> Data? {
        if let payload = payloadProvider?.latestQuotaConnectivityPayload(),
           let data = try? JSONEncoder.quotaPulse.encode(payload) {
            return data
        }
        return session.applicationContext[payloadKey] as? Data
    }

    nonisolated private func handleReceivedContext(_ context: [String: Any]) {
        Task { @MainActor in
            if let data = context[self.payloadKey] as? Data {
                self.decode(data)
            }
            self.decodeSurfaceReport(context)
        }
    }
}

extension QuotaConnectivitySession: WCSessionDelegate {
    nonisolated public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.consumeLastReceivedContext()
            if activationState == .activated, error == nil {
                self.flushPendingContext()
                #if os(watchOS)
                if self.shouldRequestLatestPayload {
                    self.requestLatestPayload()
                }
                #endif
            }
        }
    }

    nonisolated public func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in
            #if os(watchOS)
            self.requestLatestPayload()
            #endif
        }
    }

    nonisolated public func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard message[requestLatestPayloadKey] as? Bool == true else {
            replyHandler([:])
            return
        }

        Task { @MainActor in
            guard let data = self.latestPayloadData(for: session) else {
                replyHandler([:])
                return
            }
            replyHandler([self.payloadKey: data])
        }
    }

    nonisolated public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handleReceivedContext(applicationContext)
    }

    #if os(iOS)
    nonisolated public func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif
}
#endif
