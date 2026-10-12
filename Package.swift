// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentMeter",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AgentMeter", targets: ["AgentMeter"])],
    targets: [
        .executableTarget(name: "AgentMeter")
    ]
)
