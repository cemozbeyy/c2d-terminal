// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SwiftTermSpike",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.0"),
        .package(path: "../../Packages/C2DCore"),
    ],
    targets: [
        .executableTarget(name: "SwiftTermSpike", dependencies: ["SwiftTerm", "C2DCore"]),
    ]
)
