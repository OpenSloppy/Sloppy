// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SloppyConsoleProtocol",
    platforms: [.macOS(.v15), .iOS(.v26), .visionOS(.v26)],
    products: [.library(name: "SloppyConsoleProtocol", targets: ["SloppyConsoleProtocol"])],
    dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0")],
    targets: [
        .target(name: "SloppyConsoleProtocol", dependencies: [.product(name: "Crypto", package: "swift-crypto")], sources: ["ConsoleModels.swift", "ConsoleTrust.swift", "ConsoleSSO.swift", "ConsoleInstanceTrustStore.swift"]),
        .testTarget(name: "SloppyConsoleProtocolTests", dependencies: ["SloppyConsoleProtocol"]),
    ]
)
