// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "JackApp",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.7.12"),
        .package(url: "https://github.com/get-convex/convex-swift.git", from: "0.5.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.1"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "JackApp",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "ConvexMobile", package: "convex-swift"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/JackApp",
            resources: [
                .process("Resources"),
            ]),
        .testTarget(
            name: "JackAppTests",
            dependencies: ["JackApp"],
            path: "Tests/JackAppTests"
        ),
    ]
)
