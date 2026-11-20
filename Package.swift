// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NotchIsland",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "NotchIsland"),
        .testTarget(name: "NotchIslandTests", dependencies: ["NotchIsland"]),
    ]
)
