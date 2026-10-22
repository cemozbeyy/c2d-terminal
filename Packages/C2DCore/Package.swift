// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "C2DCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "C2DCore", targets: ["C2DCore"])],
    targets: [
        .target(name: "C2DCore"),
        // Token Saver PostToolUse helper (ADR-035, PROPOSED): C2DCore only, so a hook does not start the whole app.
        // Built and tested here; not bundled or wired into any launch yet.
        .executableTarget(name: "c2d-token-helper", dependencies: ["C2DCore"]),
        .testTarget(name: "C2DCoreTests", dependencies: ["C2DCore"]),
    ]
)
