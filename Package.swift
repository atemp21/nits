// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "nits",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NitsCore", targets: ["NitsCore"]),
        .executable(name: "nitsprobe", targets: ["nitsprobe"]),
    ],
    targets: [
        .target(name: "NitsCore"),
        .executableTarget(name: "nitsprobe", dependencies: ["NitsCore"]),
        .testTarget(name: "NitsCoreTests", dependencies: ["NitsCore"]),
    ]
)
