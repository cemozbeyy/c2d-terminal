// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "C2DCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "C2DCore", targets: ["C2DCore"])],
    targets: [
        .target(name: "C2DCore"),
        .testTarget(name: "C2DCoreTests", dependencies: ["C2DCore"]),
    ]
)
