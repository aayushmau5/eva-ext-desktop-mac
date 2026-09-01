// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EvaDesktopHelper",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "EvaDesktopHelper", targets: ["EvaDesktopHelper"])
    ],
    targets: [
        .executableTarget(
            name: "EvaDesktopHelper",
            path: "Sources/EvaDesktopHelper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EvaDesktopHelperTests",
            dependencies: ["EvaDesktopHelper"],
            path: "Tests/EvaDesktopHelperTests"
        )
    ]
)
