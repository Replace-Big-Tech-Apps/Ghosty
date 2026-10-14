// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ghosty",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Ghosty",
            path: "Sources/Ghosty",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        )
    ]
)
