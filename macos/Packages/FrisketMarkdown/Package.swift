// swift-tools-version: 5.10
// The live-preview scanner: finds the Markdown constructs in a note and says
// which characters are syntax (to be masked when the caret is elsewhere) and
// which blocks render as tables, math, images or rules. No AppKit.
import PackageDescription

let package = Package(
    name: "FrisketMarkdown",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FrisketMarkdown", targets: ["FrisketMarkdown"]),
    ],
    targets: [
        .target(name: "FrisketMarkdown"),
        .testTarget(name: "FrisketMarkdownTests", dependencies: ["FrisketMarkdown"]),
    ]
)
