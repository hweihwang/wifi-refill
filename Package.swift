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
            dependencies: ["RefillCore", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "RefillCoreTests",
            dependencies: ["RefillCore"],
            swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
