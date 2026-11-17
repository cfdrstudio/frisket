// swift-tools-version: 5.10
// Importers (Evernote, Notion, Apple Notes), sync-provider detection, line
// diff, style check and completion ranking. Foundation only, no UI.
import PackageDescription

let package = Package(
    name: "FrisketServices",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FrisketServices", targets: ["FrisketServices"]),
    ],
    dependencies: [
        .package(path: "../FrisketBase"),
    ],
    targets: [
        .target(
            name: "FrisketServices",
            dependencies: [.product(name: "FrisketBase", package: "FrisketBase")]
        ),
        .testTarget(name: "FrisketServicesTests", dependencies: ["FrisketServices"]),
    ]
)
