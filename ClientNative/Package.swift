// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SloppyClient",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
        .visionOS(.v26)
    ],
    products: [
        .executable(name: "SloppyClient", targets: ["SloppyClient"]),
        .executable(name: "SloppyDesktopCompanion", targets: ["SloppyDesktopCompanion"]),
        .library(name: "SloppyClientCore", targets: ["SloppyClientCore"]),
        .library(name: "SloppyClientUI", targets: ["SloppyClientUI"]),
        .library(name: "SloppyFeatureOverview", targets: ["SloppyFeatureOverview"]),
        .library(name: "SloppyFeatureProjects", targets: ["SloppyFeatureProjects"]),
        .library(name: "SloppyFeatureAgents", targets: ["SloppyFeatureAgents"]),
        .library(name: "SloppyFeatureSettings", targets: ["SloppyFeatureSettings"]),
        .library(name: "SloppyFeatureChat", targets: ["SloppyFeatureChat"]),
        .library(name: "SloppyFeatureSites", targets: ["SloppyFeatureSites"]),
        .library(name: "SloppyLiveActivity", targets: ["SloppyLiveActivity"])
    ],
    dependencies: [
        .package(path: "../Packages/SloppyMigration"),
        .package(path: "../Packages/SloppyRemoteProtocol"),
        .package(path: "../Packages/SloppyConsoleProtocol"),
        .package(path: "../Packages/SloppyComputerControl"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(path: "Vendor/Textual"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "SloppyClientCore",
            dependencies: [
                .product(name: "SloppyMigration", package: "SloppyMigration"),
                "CSQLite3",
                .product(name: "SloppyRemoteProtocol", package: "SloppyRemoteProtocol"),
                .product(name: "SloppyConsoleProtocol", package: "SloppyConsoleProtocol"),
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/SloppyClientCore"
        ),
        .target(
            name: "SloppyClientUI",
            dependencies: [
                "SloppyClientCore"
            ],
            path: "Sources/SloppyClientUI",
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "SloppyFeatureOverview",
            dependencies: [
                "SloppyClientCore",
                "SloppyClientUI"
            ],
            path: "Sources/SloppyFeatureOverview"
        ),
        .target(
            name: "SloppyFeatureProjects",
            dependencies: [
                "SloppyClientCore",
                "SloppyClientUI",
                .product(name: "Textual", package: "textual")
            ],
            path: "Sources/SloppyFeatureProjects"
        ),
        .target(
            name: "SloppyFeatureAgents",
            dependencies: [
                "SloppyClientCore",
                "SloppyClientUI",
                "SloppyFeatureChat"
            ],
            path: "Sources/SloppyFeatureAgents"
        ),
        .target(
            name: "SloppyFeatureSettings",
            dependencies: [
                "SloppyClientCore",
                "SloppyClientUI",
                "SloppyFeatureAgents",
                .product(name: "SloppyRemoteProtocol", package: "SloppyRemoteProtocol")
            ],
            path: "Sources/SloppyFeatureSettings"
        ),
        .target(
            name: "SloppyFeatureChat",
            dependencies: [
                "SloppyClientCore",
                "SloppyClientUI",
                .product(name: "Textual", package: "textual")
            ],
            path: "Sources/SloppyFeatureChat"
        ),
        .target(
            name: "SloppyFeatureSites",
            dependencies: [
                "SloppyClientCore",
                "SloppyClientUI"
            ],
            path: "Sources/SloppyFeatureSites"
        ),
        .target(
            name: "SloppyLiveActivity",
            dependencies: [
                "SloppyClientCore"
            ],
            path: "Sources/SloppyLiveActivity"
        ),
        .executableTarget(
            name: "SloppyClient",
            dependencies: [
                "SloppyClientCore",
                .product(name: "SloppyRemoteProtocol", package: "SloppyRemoteProtocol"),
                "SloppyClientUI",
                "SloppyFeatureOverview",
                "SloppyFeatureProjects",
                "SloppyFeatureAgents",
                "SloppyFeatureSettings",
                "SloppyFeatureChat",
                "SloppyFeatureSites",
                "SloppyLiveActivity",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/SloppyClient",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "SloppyDesktopCompanion",
            dependencies: [
                "SloppyClientCore",
                .product(name: "SloppyComputerControl", package: "SloppyComputerControl")
            ],
            path: "Sources/SloppyDesktopCompanion",
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "SloppyDesktopCompanionTests",
            dependencies: ["SloppyDesktopCompanion"],
            path: "Tests/SloppyDesktopCompanionTests"
        ),
        .testTarget(
            name: "SloppyClientTests",
            dependencies: ["SloppyClient"],
            path: "Tests/SloppyClientTests"
        ),
        .testTarget(
            name: "SloppyClientCoreTests",
            dependencies: ["SloppyClientCore", "SloppyLiveActivity", "CSQLite3"],
            path: "Tests/SloppyClientCoreTests"
        ),
        .testTarget(
            name: "SloppyFeatureChatTests",
            dependencies: ["SloppyClientCore", "SloppyFeatureChat"],
            path: "Tests/SloppyFeatureChatTests"
        ),
        .testTarget(
            name: "SloppyFeatureProjectsTests",
            dependencies: ["SloppyClientCore", "SloppyFeatureProjects"],
            path: "Tests/SloppyFeatureProjectsTests"
        ),
        .testTarget(
            name: "SloppyFeatureSitesTests",
            dependencies: ["SloppyClientCore", "SloppyFeatureSites"],
            path: "Tests/SloppyFeatureSitesTests"
        ),
        .systemLibrary(
            name: "CSQLite3",
            path: "Sources/CSQLite3"
        )
    ]
)
