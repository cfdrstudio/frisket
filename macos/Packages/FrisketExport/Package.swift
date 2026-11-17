// swift-tools-version: 5.10
// Export pipeline for Frisket: Markdown -> HTML body, standalone export
// documents, plain text, Markdown-with-attachments and Pandoc conversion.
// Foundation only; the app does the WebKit PDF/JPEG/print step with the HTML.
import PackageDescription

let package = Package(
    name: "FrisketExport",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FrisketExport", targets: ["FrisketExport"]),
    ],
    dependencies: [
        .package(path: "../FrisketBase"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.7.0"),
    ],
    targets: [
        .target(
            name: "FrisketExport",
            dependencies: [
                .product(name: "FrisketBase", package: "FrisketBase"),
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
        .testTarget(
            name: "FrisketExportTests",
            dependencies: ["FrisketExport"]
        ),
    ]
)
