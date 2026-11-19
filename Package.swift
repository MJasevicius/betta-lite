// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BettaLite",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BettaLite",
            path: "Sources/BettaLite",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        )
    ]
)
