import Foundation
import CryptoKit
import FrisketBase

/// Extensions for attachment MIME types, used to name unnamed resources and saved `data:` images.
public let mimeExtensions: [String: String] = [
    "image/png": ".png", "image/jpeg": ".jpg", "image/jpg": ".jpg", "image/gif": ".gif", "image/webp": ".webp",
    "image/svg+xml": ".svg", "image/heic": ".heic", "image/bmp": ".bmp", "image/tiff": ".tif",
    "application/pdf": ".pdf", "audio/mpeg": ".mp3", "audio/wav": ".wav", "audio/x-m4a": ".m4a", "video/mp4": ".mp4",
    "text/plain": ".txt", "text/html": ".html", "application/zip": ".zip",
    "application/msword": ".doc", "application/vnd.openxmlformats-officedocument.wordprocessingml.document": ".docx",
    "application/vnd.ms-excel": ".xls", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": ".xlsx",
]

/// Evernote export (.enex) reader. ENEX is regular enough to read without an
/// XML library (and a tolerant text scan survives the slightly malformed files
/// Evernote writes): a sequence of `<note>` elements, each with a title, ENML
/// content in CDATA, dates, tags and base64 `<resource>` attachments that the
/// content refers to by MD5 hash.
public enum Enex {
    /// Parse an ENEX document into notes (`key` and `folder` are left for the caller).
    public static func parse(_ xml: String) throws -> [ImportedNote] {
        guard Rx("<en-export[\\s>]").test(xml) else { throw ImportError("This file is not an Evernote export (.enex).") }
        var notes: [ImportedNote] = []
        let source = xml as NSString
        for match in Rx("<note>([\\s\\S]*?)</note>").matches(source) {
            let body = match.group(1, in: source) ?? ""
            let resources = allElements(body, "resource").enumerated().map { index, resource in
                makeResource(resource, index: index)
            }
            let content = textOf(element(body, "content")) ?? ""
            var html = Rx("^\\s*<\\?xml[\\s\\S]*?\\?>").replace(content, template: "")
            html = Rx("<!DOCTYPE[^>]*>", [.caseInsensitive]).first(html).map { m in
                (html as NSString).replacingCharacters(in: m.range, with: "")
            } ?? html
            let title = (textOf(element(body, "title")) ?? "").jsTrimmed
            notes.append(ImportedNote(
                key: "",
                title: title.isEmpty ? "Untitled" : title,
                html: html,
                created: enexDate(textOf(element(body, "created"))),
                updated: enexDate(textOf(element(body, "updated"))),
                tags: allElements(body, "tag").compactMap { textOf($0)?.jsTrimmed }.filter { !$0.isEmpty },
                resources: resources))
        }
        return notes
    }

    /// `20231012T101010Z` becomes `2023-10-12T10:10:10.000Z`; anything else is nil.
    public static func enexDate(_ value: String?) -> String? {
        let text = (value ?? "").jsTrimmed
        guard let m = Rx("^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z\\z").first(text) else { return nil }
        let g = (1...6).map { m.group($0, in: text) ?? "" }
        return "\(g[0])-\(g[1])-\(g[2])T\(g[3]):\(g[4]):\(g[5]).000Z"
    }

    private static func makeResource(_ resource: String, index: Int) -> ImportedResource {
        let dataText = Rx("<data(?:\\s[^>]*)?>([\\s\\S]*?)</data>").first(resource).flatMap { $0.group(1, in: resource) } ?? ""
        let data = decodeBase64(dataText)
        let mime = (textOf(element(resource, "mime")) ?? "").jsTrimmed
        let mimeType = mime.isEmpty ? "application/octet-stream" : mime
        let attributes = element(resource, "resource-attributes") ?? ""
        let fileName = (textOf(element(attributes, "file-name")) ?? "").jsTrimmed
        let name = fileName.isEmpty ? "attachment-\(index + 1)" + (mimeExtensions[mimeType] ?? "") : fileName
        return ImportedResource(hash: md5Hex(data), mime: mimeType, name: name, data: data)
    }

    private static func element(_ source: String, _ name: String) -> String? {
        let match = Rx("<" + name + "(?:\\s[^>]*)?>([\\s\\S]*?)</" + name + ">").first(source)
        return match.flatMap { $0.group(1, in: source) }
    }

    private static func allElements(_ source: String, _ name: String) -> [String] {
        let ns = source as NSString
        return Rx("<" + name + "(?:\\s[^>]*)?>([\\s\\S]*?)</" + name + ">").matches(ns).compactMap { $0.group(1, in: ns) }
    }

    /// Text of an element that may be CDATA or entity-escaped.
    private static func textOf(_ value: String?) -> String? {
        guard let value else { return nil }
        let ns = value as NSString
        if let m = Rx("^\\s*<!\\[CDATA\\[([\\s\\S]*?)\\]\\]>\\s*\\z").first(ns) { return m.group(1, in: ns) }
        return decodeHTMLEntities(value)
    }
}

/// Lenient base64: whitespace and missing padding are tolerated, like Node's `Buffer.from(…, 'base64')`.
func decodeBase64(_ text: String) -> Data {
    var clean = String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    let remainder = clean.utf8.count % 4
    if remainder != 0 { clean += String(repeating: "=", count: 4 - remainder) }
    return Data(base64Encoded: clean, options: [.ignoreUnknownCharacters]) ?? Data()
}

func md5Hex(_ data: Data) -> String {
    Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
