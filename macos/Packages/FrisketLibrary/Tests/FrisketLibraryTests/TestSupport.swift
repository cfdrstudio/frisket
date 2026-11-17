import XCTest
import Foundation
@testable import FrisketLibrary

extension XCTestCase {
    /// A fresh temporary directory (symlinks resolved), removed when the test ends.
    func makeTempDir(_ prefix: String = "frisket-test") throws -> String {
        let base = NSTemporaryDirectory() + "/" + prefix + "-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let real = realpath(base, nil).map { String(cString: $0) } ?? base
        addTeardownBlock { try? FileManager.default.removeItem(atPath: real) }
        return real
    }

    @discardableResult
    func write(_ root: String, _ relative: String, _ content: String = "", mtime: Date? = nil) throws -> String {
        let full = root + "/" + relative
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: URL(fileURLWithPath: full))
        if let mtime { try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: full) }
        return full
    }

    func read(_ path: String) throws -> String {
        String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
    }
}

func u(_ path: String) -> URL { URL(fileURLWithPath: path) }
