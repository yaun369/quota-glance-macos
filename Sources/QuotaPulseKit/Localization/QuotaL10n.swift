import Foundation

/// Where QuotaPulseKit's own user-facing copy is looked up.
///
/// **Why this module ships `.lproj` tables and not a `.xcstrings` catalog.**
/// The apps use a String Catalog, but the kit cannot: SwiftPM copies an
/// `.xcstrings` into the resource bundle verbatim instead of compiling it, so
/// `swift test`, `quota-cli` and `claude-status-helper` would read English no
/// matter what the system language is — and the kit is exactly where the
/// wording that four surfaces share lives. Compiled `.strings` +
/// `.stringsdict` are understood by both build systems, so the same table
/// answers an Xcode-built app and a `swift build` command line tool.
///
/// Nothing here imports SwiftUI. Localizing the kit must not drag a UI
/// dependency into a module that has none.
enum QuotaL10n {

    /// The bundle a lookup should read from.
    ///
    /// `locale == nil` — every call from the apps — hands the choice to
    /// `Bundle.module`, so the system's own resolution applies and honors the
    /// user's preferred language order and any per-app language override.
    ///
    /// An explicit locale resolves that language's `.lproj` sub-bundle
    /// instead. That indirection is not optional: `String(localized:locale:)`
    /// uses its `locale` argument to format the numbers *inside* a string, not
    /// to pick which translation of it to load. Passing `Locale(identifier:
    /// "zh-Hans")` alone returns English. Tests are the only caller.
    static func bundle(for locale: Locale?) -> Bundle {
        guard let locale else { return .module }
        let preferences = [
            locale.identifier.replacingOccurrences(of: "_", with: "-"),
            locale.language.languageCode?.identifier,
        ].compactMap { $0 }
        guard
            let match = Bundle.preferredLocalizations(
                from: Bundle.module.localizations,
                forPreferences: preferences
            ).first,
            let path = Bundle.module.path(forResource: match, ofType: "lproj"),
            let localized = Bundle(path: path)
        else { return .module }
        return localized
    }

    /// One localized string.
    ///
    /// `key` is symbolic (`"quota.window.session"`) rather than the English
    /// text, because the plural entries below have to be keyed that way for
    /// `.stringsdict` to reach them, and one convention across the table beats
    /// two. `defaultValue` carries the English source *and* the interpolated
    /// arguments, so a key missing from a translation still renders correctly
    /// instead of printing its own name.
    static func string(
        _ key: StaticString,
        _ defaultValue: String.LocalizationValue,
        locale: Locale? = nil
    ) -> String {
        String(
            localized: key,
            defaultValue: defaultValue,
            bundle: bundle(for: locale),
            locale: locale ?? .autoupdatingCurrent
        )
    }
}
