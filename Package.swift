// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Framepick",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Framepick", targets: ["Framepick"]),
        .library(name: "FramepickCore", targets: ["FramepickCore"])
    ],
    targets: [
        .target(name: "FramepickCore"),
        .executableTarget(name: "Framepick", dependencies: ["FramepickCore"]),
        .testTarget(name: "FramepickCoreTests", dependencies: ["FramepickCore", "Framepick"], resources: [.copy("Fixtures")])
    ]
)
