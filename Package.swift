// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "ClassicCommander",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(
            name: "ClassicCommander",
            targets: ["ClassicCommander"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "ClassicCommander",
            dependencies: [],
            path: "Sources/App"
        ),
        .testTarget(
            name: "AppTests",
            dependencies: ["ClassicCommander"],
            path: "Tests/AppTests"
        )
    ]
)
