// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KinshasaApp",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.11.0"),
    ],
    targets: [
        .executableTarget(
            name: "KinshasaApp",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
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
