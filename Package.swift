// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KinshasaApp",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/rive-app/rive-ios.git", from: "6.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "KinshasaApp",
            dependencies: [
                .product(name: "RiveRuntime", package: "rive-ios"),
            ],
            path: "Sources/KinshasaApp",
            resources: [
                .process("Resources"),
            ]),
        .testTarget(
            name: "KinshasaAppTests",
            dependencies: ["KinshasaApp"],
            path: "Tests/KinshasaAppTests"
        ),
    ]
)
