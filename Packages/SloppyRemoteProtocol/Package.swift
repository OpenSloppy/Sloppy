// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SloppyRemoteProtocol",
    platforms: [.macOS(.v15), .iOS(.v26), .visionOS(.v26)],
    products: [
        .library(name: "SloppyRemoteProtocol", targets: ["SloppyRemoteProtocol"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.74.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.0"),
        .package(path: "../SloppyConsoleProtocol"),
    ],
    targets: [
        .target(
            name: "SloppyRemoteProtocol",
            dependencies: [.product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "SloppyConsoleProtocol", package: "SloppyConsoleProtocol"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")]
        ),
        .testTarget(name: "SloppyRemoteProtocolTests", dependencies: ["SloppyRemoteProtocol"]),
    ]
)
