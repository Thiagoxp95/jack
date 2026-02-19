// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KinshasaApp",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "KinshasaApp",
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
