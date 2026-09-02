import Foundation

/// 哪台设备采集了这条读数。
public enum QuotaSource: String, Codable, Sendable, CaseIterable {
    case mac
    case ios
    case watch

    /// 这个来源本身就证明了哪个常驻位存在。
    ///
    /// Mac 版**就是**菜单栏 App——它没有主窗口，能推上来一条读数就说明菜单栏
    /// 那一格已经在用户的屏幕顶上了。iPhone 和 Watch 的推送不证明任何常驻位，
    /// 那两端的小组件另有 WidgetKit 可问。
    public var provesSurface: PersistentSurface? {
        switch self {
        case .mac: return .macMenuBar
        case .ios, .watch: return nil
        }
    }
}

/// `QuotaSnapshot.sourceVersion` 的编码：`"mac/0.2.0"`。
///
/// 这个字段在 CloudKit schema 里早就存在但一直没人写过，所以用它标注来源
/// **不需要改 schema，也不会让旧版本读不动新记录**——旧客户端把它当一个它不
/// 认识的可选字符串放着就行。
///
/// 为什么要标：iPhone 想知道「用户是不是也在用 Mac 菜单栏」，唯一的证据就是
/// iCloud 里出现过一条 Mac 采集的读数。没有这个标记，同一条记录被 iPhone 自己
/// 推上去的和被 Mac 推上去的长得一模一样。
public enum QuotaSourceTag {
    private static let separator = "/"

    public static func make(_ source: QuotaSource, version: String? = nil) -> String {
        guard let version, !version.isEmpty else { return source.rawValue }
        return source.rawValue + separator + version
    }

    /// 当前进程所属端的标记，版本取自 `CFBundleShortVersionString`。
    public static func current(_ source: QuotaSource, bundle: Bundle = .main) -> String {
        make(source, version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }

    /// 解析回来源。认不出来的（含 `nil`、含未来新增的端）返回 `nil` 而不是
    /// 猜一个默认值：一条来路不明的读数不该被算作任何常驻位的证据。
    public static func source(of raw: String?) -> QuotaSource? {
        guard let raw else { return nil }
        let head = raw.split(separator: Character(separator), maxSplits: 1).first.map(String.init) ?? raw
        return QuotaSource(rawValue: head)
    }
}

extension QuotaSnapshot {
    public var source: QuotaSource? { QuotaSourceTag.source(of: sourceVersion) }

    /// 打上来源标记的副本。推送前调用；`capturedAt` 和读数本身不变。
    public func taggedAsSource(_ source: QuotaSource, bundle: Bundle = .main) -> QuotaSnapshot {
        var copy = self
        copy.sourceVersion = QuotaSourceTag.current(source, bundle: bundle)
        return copy
    }
}
