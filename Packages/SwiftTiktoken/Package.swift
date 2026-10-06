// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SwiftTiktoken",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "SwiftTiktoken", targets: ["SwiftTiktoken"])],
    targets: [.target(name: "SwiftTiktoken")]
)
