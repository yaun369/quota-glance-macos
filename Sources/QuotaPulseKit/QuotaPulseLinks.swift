import Foundation

public enum QuotaPulseLinks {
    public static let usageGuide = URL(
        string: "https://quotaglance.gpt2pdf.com"
    )!

    public static let privacyPolicy = URL(
        string: "https://quotaglance.gpt2pdf.com/privacy"
    )!

    /// GitHub's stable "latest" endpoint keeps the iPhone onboarding and the
    /// website on the current notarized DMG without a versioned URL change.
    public static let macDownload = URL(
        string: "https://github.com/yaun369/quota-glance-macos/releases/latest/download/QuotaGlance.dmg"
    )!
}
