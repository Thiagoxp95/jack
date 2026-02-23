// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KinshasaApp",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.11.0"),
        .package(url: "https://github.com/clerk/clerk-ios.git", from: "1.0.0"),
        .package(url: "https://github.com/get-convex/convex-swift.git", from: "0.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "KinshasaApp",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "ClerkKit", package: "clerk-ios"),
                .product(name: "ConvexMobile", package: "convex-swift"),
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
