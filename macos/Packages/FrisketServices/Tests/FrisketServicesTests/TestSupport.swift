import Foundation
import XCTest

/// A fresh temp directory (symlinks resolved), removed when the test ends.
func makeTempDirectory(_ testCase: XCTestCase) throws -> URL {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("frisket-services-test-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let resolved = base.resolvingSymlinksInPath()
    testCase.addTeardownBlock { try? FileManager.default.removeItem(at: resolved) }
    return resolved
}

func dir(_ base: URL, _ components: String...) throws -> URL {
    var url = base
    for component in components { url.appendPathComponent(component, isDirectory: true) }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

// MARK: Minimal stored-entry ZIP writer

private let crcTable: [UInt32] = (0..<256).map { index in
    var c = UInt32(index)
    for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    return c
}

private func crc32(_ data: Data) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
    return c ^ 0xFFFF_FFFF
}

private extension Data {
    mutating func le16(_ v: Int) { append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF)) }
    mutating func le32(_ v: Int) { le16(v & 0xFFFF); le16((v >> 16) & 0xFFFF) }
}

/// A ZIP with stored (uncompressed) entries and UTF-8 names.
func makeZip(_ entries: [(name: String, data: Data)]) -> Data {
    var locals = Data()
    var centrals = Data()
    for entry in entries {
        let name = Data(entry.name.utf8)
        let crc = Int(crc32(entry.data))
        var local = Data()
        local.le32(0x0403_4b50); local.le16(20); local.le16(0x800); local.le16(0); local.le16(0); local.le16(0x21)
        local.le32(crc); local.le32(entry.data.count); local.le32(entry.data.count); local.le16(name.count); local.le16(0)
        var central = Data()
        central.le32(0x0201_4b50); central.le16(20); central.le16(20); central.le16(0x800); central.le16(0); central.le16(0); central.le16(0x21)
        central.le32(crc); central.le32(entry.data.count); central.le32(entry.data.count); central.le16(name.count)
        central.le16(0); central.le16(0); central.le16(0); central.le16(0); central.le32(0); central.le32(locals.count)
        locals += local + name + entry.data
        centrals += central + name
    }
    var end = Data()
    end.le32(0x0605_4b50); end.le16(0); end.le16(0); end.le16(entries.count); end.le16(entries.count)
    end.le32(centrals.count); end.le32(locals.count); end.le16(0)
    return locals + centrals + end
}
