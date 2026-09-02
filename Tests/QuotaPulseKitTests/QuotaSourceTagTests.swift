import XCTest
@testable import QuotaPulseKit

final class QuotaSourceTagTests: XCTestCase {

    func testTagRoundTripsThroughTheSourceVersionField() {
        let tagged = QuotaSnapshot(provider: .codex).taggedAsSource(.mac, bundle: .main)

        XCTAssertEqual(tagged.source, .mac)
        XCTAssertTrue(tagged.sourceVersion?.hasPrefix("mac") == true)
    }

    func testVersionIsOptionalAndDoesNotChangeTheParsedSource() {
        XCTAssertEqual(QuotaSourceTag.make(.ios), "ios")
        XCTAssertEqual(QuotaSourceTag.make(.ios, version: "0.3.0"), "ios/0.3.0")
        XCTAssertEqual(QuotaSourceTag.source(of: "ios"), .ios)
        XCTAssertEqual(QuotaSourceTag.source(of: "ios/0.3.0"), .ios)
    }

    /// 旧记录里这个字段是空的（它在 schema 里存在但从没被写过），未来也可能出现
    /// 这一版还不认识的端。两种情况都必须解析成「不知道」，而不是猜一个默认值——
    /// 一条来路不明的读数不该被算作任何常驻位的证据。
    func testUnknownAndMissingSourcesParseToNil() {
        XCTAssertNil(QuotaSourceTag.source(of: nil))
        XCTAssertNil(QuotaSourceTag.source(of: ""))
        XCTAssertNil(QuotaSourceTag.source(of: "visionpro/1.0"))
        XCTAssertNil(QuotaSnapshot(provider: .claude).source)
    }

    /// Mac 版没有主窗口，它就是菜单栏——所以一条 Mac 采集的读数本身就是那个
    /// 常驻位存在的证据。iPhone 和 Watch 的推送证明不了任何事。
    func testOnlyTheMacProvesASurface() {
        XCTAssertEqual(QuotaSource.mac.provesSurface, .macMenuBar)
        XCTAssertNil(QuotaSource.ios.provesSurface)
        XCTAssertNil(QuotaSource.watch.provesSurface)
    }

    func testTaggingKeepsTheReadingItself() {
        let original = QuotaSnapshot(
            provider: .claude,
            session: QuotaWindow(usedPercent: 40, resetAt: Date(timeIntervalSince1970: 1)),
            weekly: QuotaWindow(usedPercent: 10, resetAt: Date(timeIntervalSince1970: 2)),
            capturedAt: Date(timeIntervalSince1970: 3)
        )

        let tagged = original.taggedAsSource(.mac)

        XCTAssertEqual(tagged.id, original.id)
        XCTAssertEqual(tagged.session, original.session)
        XCTAssertEqual(tagged.weekly, original.weekly)
        XCTAssertEqual(tagged.capturedAt, original.capturedAt)
    }
}
