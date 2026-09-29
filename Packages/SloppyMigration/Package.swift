// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SloppyMigration",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "SloppyMigration", targets: ["SloppyMigration"])],
    dependencies: [
        .package(url: "https://github.com/facebook/zstd.git", from: "1.5.7"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
    ],
    targets: [
        .systemLibrary(name: "CMigrationSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
        .target(name: "SloppyMigration", dependencies: [
            .product(name: "libzstd", package: "zstd"),
            "CMigrationSQLite", "TOMLKit", "Yams", .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .testTarget(name: "SloppyMigrationTests", dependencies: ["SloppyMigration", "CMigrationSQLite", .product(name: "libzstd", package: "zstd")]),
    ]
)
