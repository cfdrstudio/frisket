// swift-tools-version: 5.10
// Frisket's note library: parsing, link resolution, search, version history,
// the live library index and library file operations. Foundation only (plus
// CryptoKit for hashes); no UI.
import PackageDescription

let package = Package(
    name: "FrisketLibrary",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FrisketLibrary", targets: ["FrisketLibrary"]),
    ],
    dependencies: [
        .package(path: "../FrisketBase"),
    ],
    targets: [
        .target(
            name: "FrisketLibrary",
            dependencies: [.product(name: "FrisketBase", package: "FrisketBase")]
        ),
        .testTarget(
            name: "FrisketLibraryTests",
            dependencies: ["FrisketLibrary", .product(name: "FrisketBase", package: "FrisketBase")]
        ),
    ]
)
