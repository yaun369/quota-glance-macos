import XCTest
@testable import QuotaPulseKit

/// 文案的两种语言都在这里被钉死（issue #10）。
///
/// **每个断言都显式传 locale。** 不传的话这一套测试就变成了「跑测试的这台机器
/// 是什么语言」的函数——开发机是中文，CI 是英文，同一份代码两边给出不同结论，
/// 而先红的那一边多半会被当成环境问题跳过。验收要求「切英文四端无中文」和
/// 「切中文与改造前等价」，这两件事必须能在同一次运行里被同时证明。
final class QuotaFormattingTests: XCTestCase {
    private let en = Locale(identifier: "en_US")
    private let zh = Locale(identifier: "zh-Hans")

    // MARK: - 剩余 / Remaining

    func testRemainingTextUsesRemainingNotUsed() {
        let window = QuotaWindow(usedPercent: 73, resetAt: nil)
        XCTAssertEqual(QuotaFormatting.remainingText(window, locale: zh), "剩余 27%")
        XCTAssertEqual(QuotaFormatting.remainingText(window, locale: en), "Remaining 27%")
    }

    func testRemainingTextWithNoDataYet() {
        XCTAssertEqual(QuotaFormatting.remainingText(QuotaWindow(), locale: zh), "暂无数据")
        XCTAssertEqual(QuotaFormatting.remainingText(QuotaWindow(), locale: en), "No data yet")
    }

    /// 规范 §6 的裁决：第二个量纲叫「利用率」，永远不叫「已用」。英文同理——
    /// 「utilization」而不是「used」，否则英文版偷偷把中文版立的规矩反了过来。
    func testUtilizationTextNamesUtilizationNeverUsed() {
        let window = QuotaWindow(usedPercent: 34, resetAt: nil)
        XCTAssertEqual(QuotaFormatting.utilizationText(window, locale: zh), "本窗口利用率 34%")
        XCTAssertFalse(QuotaFormatting.utilizationText(window, locale: zh)!.contains("已用"))
        XCTAssertEqual(QuotaFormatting.utilizationText(window, locale: en), "Window utilization 34%")
        XCTAssertFalse(QuotaFormatting.utilizationText(window, locale: en)!.lowercased().contains("used"))
    }

    /// The two quantities on the same card always add up to 100, including
    /// when a provider reports past the end of the window.
    func testUtilizationAndRemainingAlwaysSumTo100() {
        let window = QuotaWindow(usedPercent: 118, resetAt: nil)
        XCTAssertEqual(QuotaFormatting.utilizationText(window, locale: zh), "本窗口利用率 100%")
        XCTAssertEqual(QuotaFormatting.remainingText(window, locale: zh), "剩余 0%")
        XCTAssertEqual(QuotaFormatting.utilizationText(window, locale: en), "Window utilization 100%")
        XCTAssertEqual(QuotaFormatting.remainingText(window, locale: en), "Remaining 0%")
    }

    func testUtilizationTextIsAbsentWithoutAReading() {
        XCTAssertNil(QuotaFormatting.utilizationText(QuotaWindow(), locale: zh))
        XCTAssertNil(QuotaFormatting.utilizationText(QuotaWindow(), locale: en))
    }

    // MARK: - 窗口名 / Window names

    func testWindowNames() {
        XCTAssertEqual(QuotaFormatting.windowText(.session, locale: zh), "5 小时")
        XCTAssertEqual(QuotaFormatting.windowText(.weekly, locale: zh), "每周")
        XCTAssertEqual(QuotaFormatting.windowText(.session, locale: en), "5 hours")
        XCTAssertEqual(QuotaFormatting.windowText(.weekly, locale: en), "Weekly")
    }

    // MARK: - 错误文案 / Failure text

    /// 规范 §6：错误文案必须给出下一步动作。A system `URLError` names a cause
    /// and stops, so the next step is appended for it — in both languages.
    func testFailureTextAppendsANextStepToSystemNetworkErrors() {
        let error = URLError(.notConnectedToInternet)
        XCTAssertTrue(
            QuotaFormatting.failureText(error, locale: zh).hasSuffix("请检查网络连接后重试。"),
            QuotaFormatting.failureText(error, locale: zh)
        )
        XCTAssertTrue(
            QuotaFormatting.failureText(error, locale: en).hasSuffix("Check your network connection and try again."),
            QuotaFormatting.failureText(error, locale: en)
        )
    }

    /// The app's own errors already end in one, and must not be padded twice.
    func testFailureTextKeepsQuotaErrorWordingVerbatim() {
        let error = QuotaError.codexNotConnected
        XCTAssertEqual(QuotaFormatting.failureText(error), error.userFacingDescription)
        XCTAssertFalse(QuotaFormatting.failureText(error, locale: zh).contains("请检查网络连接后重试。"))
        XCTAssertFalse(
            QuotaFormatting.failureText(error, locale: en).contains("Check your network connection and try again.")
        )
    }

    // MARK: - 倒计时 / Reset countdown

    func testResetCountdownWithHoursAndMinutes() {
        let now = Date(timeIntervalSince1970: 0)
        let resetAt = now.addingTimeInterval(3600 + 42 * 60)
        XCTAssertEqual(QuotaFormatting.resetCountdownText(resetAt, now: now, locale: zh), "1 小时 42 分钟后重置")
        XCTAssertEqual(QuotaFormatting.resetCountdownText(resetAt, now: now, locale: en), "Resets in 1 hour 42 minutes")
    }

    func testResetCountdownWithDaysHoursAndMinutes() {
        let now = Date(timeIntervalSince1970: 0)
        let resetAt = now.addingTimeInterval(166 * 3600 + 60)
        XCTAssertEqual(QuotaFormatting.resetCountdownText(resetAt, now: now, locale: zh), "6 天 22 小时 1 分钟后重置")
        XCTAssertEqual(
            QuotaFormatting.resetCountdownText(resetAt, now: now, locale: en),
            "Resets in 6 days 22 hours 1 minute"
        )
    }

    func testResetCountdownAtExactlyOneDay() {
        let now = Date(timeIntervalSince1970: 0)
        let resetAt = now.addingTimeInterval(24 * 3600)
        XCTAssertEqual(QuotaFormatting.resetCountdownText(resetAt, now: now, locale: zh), "1 天 0 小时 0 分钟后重置")
        XCTAssertEqual(
            QuotaFormatting.resetCountdownText(resetAt, now: now, locale: en),
            "Resets in 1 day 0 hours 0 minutes"
        )
    }

    func testResetCountdownUnderAnHour() {
        let now = Date(timeIntervalSince1970: 0)
        let resetAt = now.addingTimeInterval(15 * 60)
        XCTAssertEqual(QuotaFormatting.resetCountdownText(resetAt, now: now, locale: zh), "15 分钟后重置")
        XCTAssertEqual(QuotaFormatting.resetCountdownText(resetAt, now: now, locale: en), "Resets in 15 minutes")
    }

    /// 验收第 4 条：英文下 1 和 2 必须走不同的复数形式，而且是从
    /// `Localizable.stringsdict` 里取的，不是在 Swift 里拼出来的。
    /// 每一种时长形状都要覆盖到——三段式那条最容易漏，因为它有三个独立的
    /// 复数变量，任何一个漏配都只在特定的分钟数上才看得出来。
    func testEnglishPluralsInflectEveryUnit() {
        let now = Date(timeIntervalSince1970: 0)
        func countdown(_ seconds: TimeInterval) -> String {
            QuotaFormatting.resetCountdownText(now.addingTimeInterval(seconds), now: now, locale: en)
        }
        XCTAssertEqual(countdown(60), "Resets in 1 minute")
        XCTAssertEqual(countdown(120), "Resets in 2 minutes")
        XCTAssertEqual(countdown(3600 + 60), "Resets in 1 hour 1 minute")
        XCTAssertEqual(countdown(2 * 3600 + 120), "Resets in 2 hours 2 minutes")
        XCTAssertEqual(countdown(24 * 3600 + 3600 + 60), "Resets in 1 day 1 hour 1 minute")
        XCTAssertEqual(countdown(48 * 3600 + 2 * 3600 + 120), "Resets in 2 days 2 hours 2 minutes")
    }

    /// 中文没有复数，同一批时长必须只有一种形状——把 stringsdict 里那套
    /// `one` 分类误抄进中文表的话，这条会先红。
    func testChineseHasNoPluralInflection() {
        let now = Date(timeIntervalSince1970: 0)
        func countdown(_ seconds: TimeInterval) -> String {
            QuotaFormatting.resetCountdownText(now.addingTimeInterval(seconds), now: now, locale: zh)
        }
        XCTAssertEqual(countdown(60), "1 分钟后重置")
        XCTAssertEqual(countdown(120), "2 分钟后重置")
        XCTAssertEqual(countdown(3600 + 60), "1 小时 1 分钟后重置")
        XCTAssertEqual(countdown(24 * 3600 + 3600 + 60), "1 天 1 小时 1 分钟后重置")
    }

    func testResetCountdownAfterResetMoment() {
        let now = Date(timeIntervalSince1970: 1000)
        let resetAt = Date(timeIntervalSince1970: 500)
        XCTAssertEqual(QuotaFormatting.resetCountdownText(resetAt, now: now, locale: zh), "预计已重置")
        XCTAssertEqual(QuotaFormatting.resetCountdownText(resetAt, now: now, locale: en), "Should have reset")
    }

    func testResetCountdownUnknown() {
        XCTAssertEqual(QuotaFormatting.resetCountdownText(nil, locale: zh), "重置时间未知")
        XCTAssertEqual(QuotaFormatting.resetCountdownText(nil, locale: en), "Reset time unknown")
    }

    // MARK: - 新鲜度 / Freshness

    func testFreshnessJustNow() {
        let now = Date(timeIntervalSince1970: 1000)
        let capturedAt = now.addingTimeInterval(-30)
        XCTAssertEqual(QuotaFormatting.freshnessText(capturedAt: capturedAt, now: now, locale: zh), "刚刚更新")
        XCTAssertEqual(QuotaFormatting.freshnessText(capturedAt: capturedAt, now: now, locale: en), "Updated just now")
    }

    func testFreshnessMinutesAgo() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(
            QuotaFormatting.freshnessText(capturedAt: now.addingTimeInterval(-12 * 60), now: now, locale: zh),
            "12 分钟前更新"
        )
        XCTAssertEqual(
            QuotaFormatting.freshnessText(capturedAt: now.addingTimeInterval(-12 * 60), now: now, locale: en),
            "Updated 12 minutes ago"
        )
        XCTAssertEqual(
            QuotaFormatting.freshnessText(capturedAt: now.addingTimeInterval(-60), now: now, locale: en),
            "Updated 1 minute ago"
        )
    }

    func testFreshnessHoursAgo() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(
            QuotaFormatting.freshnessText(capturedAt: now.addingTimeInterval(-3 * 3600 - 60), now: now, locale: zh),
            "3 小时前更新"
        )
        XCTAssertEqual(
            QuotaFormatting.freshnessText(capturedAt: now.addingTimeInterval(-3 * 3600 - 60), now: now, locale: en),
            "Updated 3 hours ago"
        )
        XCTAssertEqual(
            QuotaFormatting.freshnessText(capturedAt: now.addingTimeInterval(-3600 - 60), now: now, locale: en),
            "Updated 1 hour ago"
        )
    }

    // MARK: - 状态码不是数量 / Codes are identifiers, not quantities

    /// 一个状态码、端口号或 HTTP 码走 `%@` 而不是 `%lld`：`%lld` 会按 locale
    /// 加千位分隔符，把 `-25293` 印成 `-25,293`，而那串数字是拿去搜索和上报的
    /// 标识符，不是读者会拿来相加的量。
    func testStatusCodesKeepTheirDigits() {
        let text = OAuthTokenStoreError.keychainFailure(-25_293).errorDescription ?? ""
        XCTAssertTrue(text.contains("-25293"), text)
        XCTAssertFalse(text.contains("-25,293"), text)
    }

    /// -34018 is the one keychain status a user reaches without anything
    /// being broken — an unsigned build has no keychain to save into — so it
    /// gets its own sentence instead of the bare "status N" line. Asserted
    /// against the generic string rather than against English words: this
    /// test has to hold in whatever language the machine running it prefers.
    func testUnsignedBuildGetsAReasonRatherThanJustAStatusCode() {
        let unsigned = OAuthTokenStoreError.keychainFailure(errSecMissingEntitlement).errorDescription ?? ""
        let genericForSameStatus = QuotaL10n.string(
            "token.keychainFailed",
            "Keychain access failed (status \(String(errSecMissingEntitlement)))."
        )

        XCTAssertNotEqual(unsigned, genericForSameStatus)
        XCTAssertTrue(unsigned.contains("-34018"), unsigned)

        // Every other status keeps the generic line.
        XCTAssertEqual(
            OAuthTokenStoreError.keychainFailure(-25_293).errorDescription,
            QuotaL10n.string("token.keychainFailed", "Keychain access failed (status \(String(OSStatus(-25_293)))).")
        )
    }
}
