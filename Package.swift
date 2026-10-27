// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "KilobatCLI",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "kilobat", targets: ["KilobatCLI"])],
    targets: [
        .target(name: "KilobatCore"),
        .executableTarget(name: "KilobatCLI", dependencies: ["KilobatCore"]),
        .testTarget(name: "KilobatTests", dependencies: ["KilobatCore"])
    ]
)
