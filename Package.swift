// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "QuotaPulse",
    // English is the development language; 简体中文 is the second (issue #10).
    // Both live in Sources/QuotaPulseKit/Resources as compiled .lproj tables —
    // see QuotaL10n for why the kit cannot use a .xcstrings catalog.
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "QuotaPulseKit", targets: ["QuotaPulseKit"]),
        .executable(name: "quota-cli", targets: ["quota-cli"]),
        .executable(name: "claude-status-helper", targets: ["claude-status-helper"]),
    ],
    targets: [
        .target(
            name: "QuotaPulseKit",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "quota-cli",
            dependencies: ["QuotaPulseKit"]
        ),
        .executableTarget(
            name: "claude-status-helper",
            dependencies: ["QuotaPulseKit"]
        ),
        .testTarget(
            name: "QuotaPulseKitTests",
            dependencies: ["QuotaPulseKit"]
        ),
    ]
)
