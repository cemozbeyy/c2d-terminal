// swift-tools-version: 6.0
import PackageDescription

// Offline replay benchmark (ADR-034). Not part of the app target; see main.swift for usage.
let package = Package(
    name: "replay",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../Packages/C2DCore")],
    targets: [.executableTarget(name: "replay", dependencies: ["C2DCore"], path: ".", sources: ["main.swift"])]
)
