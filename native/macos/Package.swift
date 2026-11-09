// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RDPAgent",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacAgentCore", targets: ["MacAgentCore"]),
        .executable(name: "rdp-agent", targets: ["rdp-agent"]),
        .library(name: "RDPServerCore", targets: ["RDPServerCore"]),
        .executable(name: "RDPServer", targets: ["RDPServer"]),
    ],
    targets: [
        .target(name: "MacAgentCore"),
        .executableTarget(name: "rdp-agent", dependencies: ["MacAgentCore"]),
        .target(name: "RDPServerCore"),
        .executableTarget(name: "RDPServer", dependencies: ["RDPServerCore"]),
    ]
)
