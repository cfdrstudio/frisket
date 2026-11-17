// swift-tools-version: 5.10
// Shared helpers every other Frisket package builds on: front matter, file
// writes, names and regular expressions. No AppKit, no UI.
import PackageDescription

let package = Package(
    name: "FrisketBase",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FrisketBase", targets: ["FrisketBase"]),
    ],
    targets: [
        .target(name: "FrisketBase"),
        .testTarget(name: "FrisketBaseTests", dependencies: ["FrisketBase"]),
    ]
)
