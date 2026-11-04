// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "WiFiRefill",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "RefillCore",
            swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")]
        ),
        .executableTarget(
            name: "WiFiRefill",
            dependencies: ["RefillCore", "Companion", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .target(
            name: "Companion",
            dependencies: ["RefillCore"],
            swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")]
        ),
        .executableTarget(
            name: "refill-doctor",
            dependencies: ["RefillCore"],
            swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")]
        ),
        .testTarget(
            name: "CompanionTests",
            dependencies: ["Companion"],
            swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")]
        ),
        .testTarget(
            name: "RefillCoreTests",
            dependencies: ["RefillCore"],
            swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
