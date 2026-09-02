import XCTest
@testable import QuotaPulseKit

final class PersistentSurfaceTests: XCTestCase {

    // MARK: - 按设备能力分支

    func testWithoutAPairedWatchTheWatchComplicationIsNeverSuggested() {
        let surfaces = PersistentSurface.recommended(for: DeviceCapabilities())

        XCTAssertFalse(surfaces.contains(.watchComplication))
        XCTAssertEqual(surfaces, [.homeScreenWidget, .lockScreenWidget])
    }

    func testAPairedWatchAddsTheComplication() {
        let surfaces = PersistentSurface.recommended(
            for: DeviceCapabilities(hasPairedWatch: true, isWatchAppInstalled: true)
        )

        XCTAssertEqual(surfaces, [.homeScreenWidget, .lockScreenWidget, .watchComplication])
    }

    /// Mac 的存在无法从 iPhone 上问出来，所以它只在「已经确认有」的时候进主列表。
    func testMacEntersTheMainListOnlyOnceItIsKnown() {
        let unknown = PersistentSurface.recommended(for: DeviceCapabilities(knownMac: false))
        XCTAssertFalse(unknown.contains(.macMenuBar))

        let known = PersistentSurface.recommended(for: DeviceCapabilities(knownMac: true))
        XCTAssertTrue(known.contains(.macMenuBar))
    }

    /// 「不知道有没有」才配进次级入口；「知道没有」不配——没配表的人不该在任何
    /// 位置看到「添加表盘复杂功能」。
    func testOpportunitiesOfferOnlyTheUnknowableDevice() {
        let opportunities = PersistentSurface.opportunities(for: DeviceCapabilities())

        XCTAssertEqual(opportunities, [.macMenuBar])
    }

    func testAKnownMacIsNotOfferedTwice() {
        let capabilities = DeviceCapabilities(knownMac: true)

        XCTAssertTrue(PersistentSurface.recommended(for: capabilities).contains(.macMenuBar))
        XCTAssertTrue(PersistentSurface.opportunities(for: capabilities).isEmpty)
    }

    // MARK: - 已添加的排序

    func testAlreadyAddedSurfacesSinkButStay() {
        let surfaces = PersistentSurface.recommended(
            for: DeviceCapabilities(hasPairedWatch: true),
            alreadyAdded: [.homeScreenWidget]
        )

        // 沉底，但不消失：用户需要看到自己已经完成了哪一个。
        XCTAssertEqual(surfaces, [.lockScreenWidget, .watchComplication, .homeScreenWidget])
    }

    /// 一台没有 Mac 记录、但云端来过 Mac 数据的设备：`alreadyAdded` 本身就足以
    /// 让那一条留在列表里，不必等 `knownMac` 也被写上。
    func testAnAlreadyAddedMacStaysListedEvenWhenUnknown() {
        let surfaces = PersistentSurface.recommended(
            for: DeviceCapabilities(knownMac: false),
            alreadyAdded: [.macMenuBar]
        )

        XCTAssertEqual(surfaces, [.homeScreenWidget, .lockScreenWidget, .macMenuBar])
    }

    // MARK: - 步骤按设备情况补齐

    /// 配了表但没装码量的人，照着「长按表盘 → 编辑 → 选码量」会在第三步
    /// 找不到码量，然后得出「这个 App 坏了」的结论。
    func testAWatchWithoutTheAppGetsAnExtraInstallStep() {
        let withApp = DeviceCapabilities(hasPairedWatch: true, isWatchAppInstalled: true)
        let withoutApp = DeviceCapabilities(hasPairedWatch: true, isWatchAppInstalled: false)

        let base = PersistentSurface.watchComplication.steps(for: withApp)
        let extended = PersistentSurface.watchComplication.steps(for: withoutApp)

        XCTAssertEqual(base, PersistentSurface.watchComplication.steps)
        XCTAssertEqual(extended.count, base.count + 1)
        XCTAssertEqual(Array(extended.dropFirst()), base)
    }

    func testOtherSurfacesIgnoreTheWatchInstallState() {
        let capabilities = DeviceCapabilities(hasPairedWatch: true, isWatchAppInstalled: false)

        for surface in PersistentSurface.allCases where surface != .watchComplication {
            XCTAssertEqual(surface.steps(for: capabilities), surface.steps, "\(surface) 不该受手表状态影响")
        }
    }

    // MARK: - 文案完整性

    func testEverySurfaceCarriesItsOwnSteps() {
        for surface in PersistentSurface.allCases {
            XCTAssertFalse(surface.title.isEmpty, "\(surface) 缺标题")
            XCTAssertFalse(surface.promise.isEmpty, "\(surface) 缺好处说明")
            XCTAssertFalse(surface.symbolName.isEmpty, "\(surface) 缺图标")
            XCTAssertFalse(surface.steps.isEmpty, "\(surface) 缺添加步骤")
        }
    }
}
