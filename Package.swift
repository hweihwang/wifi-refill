// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "WifiAutologin",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WifiAutologin",
            path: "Sources",
            swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")]
        ),
    ]
)
