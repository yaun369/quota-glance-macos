import XCTest
@testable import QuotaPulseKit

/// 把事件收下来，供断言检查——真正的上报后端还不存在（见
/// docs/activation-observability.md）。
private final class RecordingSink: ActivationEventSink, @unchecked Sendable {
    private(set) var events: [ActivationEvent] = []

    func record(_ event: ActivationEvent, at date: Date) {
        events.append(event)
    }

    var names: [String] { events.map(\.name) }
}

@MainActor
final class ActivationTrackerTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults.standard
    private var sink = RecordingSink()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "quotapulse.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        sink = RecordingSink()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeTracker() -> ActivationTracker {
        ActivationTracker(defaults: defaults, storageKey: "activation", sinks: [sink], now: { self.now })
    }

    // MARK: - 基础 Activation

    func testFirstRealQuotaIsBasicActivationAndImpliesAConnection() {
        let tracker = makeTracker()
        XCTAssertFalse(tracker.isBasicallyActivated)

        tracker.noteRealQuota(for: .codex)

        XCTAssertTrue(tracker.isBasicallyActivated)
        XCTAssertFalse(tracker.isStronglyActivated)
        // 拿到读数必然意味着连接成功过，所以连接事件不需要调用方再补一次。
        XCTAssertEqual(sink.names, ["provider_connected", "activation_basic"])
        XCTAssertEqual(tracker.milestones.firstRealQuotaAt, now)
    }

    func testBasicActivationFiresOnlyOnceAcrossProviders() {
        let tracker = makeTracker()

        tracker.noteRealQuota(for: .codex)
        tracker.noteRealQuota(for: .codex)
        tracker.noteRealQuota(for: .claude)

        XCTAssertEqual(sink.names.filter { $0 == "activation_basic" }.count, 1)
        // 第二个 provider 的连接是新事实，仍然要记。
        XCTAssertEqual(sink.names.filter { $0 == "provider_connected" }.count, 2)
    }

    // MARK: - 更强 Activation

    func testStrongActivationNeedsBothAQuotaAndASurface() {
        let tracker = makeTracker()

        tracker.noteSurfaceDetected(.homeScreenWidget)
        XCTAssertFalse(tracker.isStronglyActivated, "没有真实额度就不算 Activation")

        tracker.noteRealQuota(for: .claude)
        XCTAssertTrue(tracker.isStronglyActivated)
    }

    /// 探测是轮询式的，去重必须在 tracker 里做——否则每 60 秒就多一条
    /// 「更强 Activation」，指标会变成一个计时器。
    func testRepeatedDetectionOfTheSameSurfaceEmitsOnce() {
        let tracker = makeTracker()

        tracker.noteSurfacesDetected([.homeScreenWidget, .lockScreenWidget])
        tracker.noteSurfacesDetected([.homeScreenWidget, .lockScreenWidget])
        tracker.noteSurfacesDetected([.homeScreenWidget])

        XCTAssertEqual(sink.names.filter { $0 == "activation_strong" }.count, 2)
    }

    /// 用户把小组件删了，不撤销一次已经发生过的 Activation——它是历史事实，
    /// 不是当前状态。
    func testADisappearingSurfaceDoesNotUnlatchTheMilestone() {
        let tracker = makeTracker()
        tracker.noteRealQuota(for: .codex)
        tracker.noteSurfaceDetected(.homeScreenWidget)

        tracker.noteSurfacesDetected([])

        XCTAssertTrue(tracker.isStronglyActivated)
        XCTAssertEqual(tracker.detectedSurfaces, [.homeScreenWidget])
    }

    // MARK: - 引导本身

    func testGuideOnlyAutoPresentsAfterBasicActivationAndBeforeAnySurface() {
        let tracker = makeTracker()
        XCTAssertFalse(tracker.shouldPresentSurfaceGuide, "还没连上账号时不该弹")

        tracker.noteRealQuota(for: .codex)
        XCTAssertTrue(tracker.shouldPresentSurfaceGuide)

        tracker.noteSurfaceDetected(.lockScreenWidget)
        XCTAssertFalse(tracker.shouldPresentSurfaceGuide, "已经有常驻位就不必再引导")
    }

    func testDismissingTheGuideStopsItFromComingBack() {
        let tracker = makeTracker()
        tracker.noteRealQuota(for: .codex)

        tracker.noteGuideDismissed()

        XCTAssertFalse(tracker.shouldPresentSurfaceGuide)
        XCTAssertEqual(sink.events.last, .surfaceGuideDismissed(completed: false))
    }

    func testGuideShownCountsEveryTimeBecauseItIsTheProxyDenominator() {
        let tracker = makeTracker()

        tracker.noteGuideShown([.homeScreenWidget])
        tracker.noteGuideShown([.homeScreenWidget])

        XCTAssertEqual(tracker.milestones.guideShownCount, 2)
        XCTAssertEqual(tracker.milestones.guideFirstShownAt, now)
        XCTAssertEqual(sink.names.filter { $0 == "surface_guide_shown" }.count, 2)
    }

    func testOpeningTheSameStepTwiceIsOneEvent() {
        let tracker = makeTracker()

        tracker.noteGuideOpened(.lockScreenWidget)
        tracker.noteGuideOpened(.lockScreenWidget)

        XCTAssertEqual(sink.names.filter { $0 == "surface_guide_opened" }.count, 1)
    }

    // MARK: - 持久化

    func testMilestonesSurviveARelaunch() {
        let first = makeTracker()
        first.noteRealQuota(for: .claude)
        first.noteSurfaceDetected(.homeScreenWidget)

        let second = ActivationTracker(defaults: defaults, storageKey: "activation", now: { self.now })

        XCTAssertTrue(second.isStronglyActivated)
        XCTAssertEqual(second.detectedSurfaces, [.homeScreenWidget])
        XCTAssertEqual(second.milestones.firstRealQuotaAt, now)
    }

    /// 冷启动后重新探测到同一个小组件，不该再发一次事件。
    func testARelaunchDoesNotReEmitAlreadyLatchedMilestones() {
        let first = makeTracker()
        first.noteSurfaceDetected(.homeScreenWidget)

        let secondSink = RecordingSink()
        let second = ActivationTracker(
            defaults: defaults,
            storageKey: "activation",
            sinks: [secondSink],
            now: { self.now }
        )
        second.noteSurfaceDetected(.homeScreenWidget)

        XCTAssertTrue(secondSink.events.isEmpty)
    }
}
