// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SloppyComputerControl",
    platforms: [
        .iOS(.v18),
        .macOS(.v14)
    ],
    products: [
        .library(name: "SloppyComputerControl", targets: ["SloppyComputerControl"])
    ],
    targets: [
        .target(
            name: "SloppyComputerControl",
            path: "Sources/SloppyComputerControl"
        ),
        .testTarget(
            name: "SloppyComputerControlTests",
            dependencies: ["SloppyComputerControl"],
            path: "Tests/SloppyComputerControlTests"
        )
    ]
)
