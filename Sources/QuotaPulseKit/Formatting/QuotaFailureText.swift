import Foundation

extension QuotaFormatting {

    /// One failure message, phrased the way §6 requires: it says what went
    /// wrong **and** what to do next.
    ///
    /// The order matters. `QuotaError` and the app's own `LocalizedError`s
    /// already end in a next step ("Please sign in again", "The button below
    /// sets it up automatically"), so they are used verbatim. What is left is
    /// the system's own text — a `URLError`'s "The Internet connection appears
    /// to be offline." names a cause and stops there, which on a badge under a
    /// stale reading leaves the reader with nothing to do. That case gets the
    /// next step appended here, once, instead of at each of the four call
    /// sites that show it.
    ///
    /// `urlError.localizedDescription` is the system's own translation, so
    /// this line is already bilingual before it reaches the catalog; only the
    /// sentence appended to it is ours.
    public static func failureText(_ error: Error, locale: Locale? = nil) -> String {
        if let quotaError = error as? QuotaError {
            return quotaError.userFacingDescription
        }
        if let urlError = error as? URLError {
            let description = urlError.localizedDescription
            return QuotaL10n.string(
                "quota.failure.checkNetwork",
                "\(description) Check your network connection and try again.",
                locale: locale
            )
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
