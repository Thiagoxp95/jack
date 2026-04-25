// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "JackApp",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(path: "Packages/FluidAudio"),
        .package(url: "https://github.com/clerk/clerk-ios.git", from: "1.0.0"),
        .package(url: "https://github.com/get-convex/convex-swift.git", from: "0.5.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.1"),
    ],
    targets: [
        .executableTarget(
            name: "JackApp",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "ClerkKit", package: "clerk-ios"),
                .product(name: "ConvexMobile", package: "convex-swift"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
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
