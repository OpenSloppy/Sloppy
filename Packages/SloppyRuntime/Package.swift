// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SloppyRuntimePortable",
    platforms: [.iOS(.v18), .visionOS(.v2), .macOS(.v15)],
    products: [
        .library(name: "SloppyRuntime", targets: ["SloppyRuntime"]),
        .library(name: "AgentRuntime", targets: ["AgentRuntime"]),
        .library(name: "PluginSDK", targets: ["PluginSDK"]),
        .library(name: "Protocols", targets: ["Protocols"]),
    ],
    dependencies: [
        .package(path: "../SloppyComputerControl"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.4.1"),
        .package(url: "https://github.com/mattt/AnyLanguageModel.git", branch: "main"),
    ],
    targets: [
        .target(name: "Protocols", dependencies: [
            .product(name: "SloppyComputerControl", package: "SloppyComputerControl"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        .target(name: "PluginSDK", dependencies: [
            "Protocols",
            .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        .target(name: "AgentRuntime", dependencies: [
            "Protocols", "PluginSDK",
            .product(name: "Logging", package: "swift-log"),
            .product(name: "Metrics", package: "swift-metrics"),
        ]),
        .target(name: "SloppyRuntime", dependencies: [
            "AgentRuntime", "PluginSDK", "Protocols",
            .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
        ], resources: [.copy("Resources/Prompts")]),
        .testTarget(name: "SloppyRuntimeTests", dependencies: ["SloppyRuntime", "Protocols"]),
    ]
)
