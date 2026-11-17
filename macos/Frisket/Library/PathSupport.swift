import Foundation

extension URL {
    /// The path with symlinks resolved by realpath(3). Unlike `resolvingSymlinksInPath()`,
    /// this keeps the `/private` prefix, so it matches the library index and FSEvents paths.
    var canonicalPath: String {
        guard let resolved = realpath(standardizedFileURL.path, nil) else { return standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Do two URLs name the same file (through symlinks)?
func sameFile(_ a: URL?, _ b: URL?) -> Bool {
    guard let a, let b else { return false }
    return a.standardizedFileURL == b.standardizedFileURL || a.canonicalPath == b.canonicalPath
}
