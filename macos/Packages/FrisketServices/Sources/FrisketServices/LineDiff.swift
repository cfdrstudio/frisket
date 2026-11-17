import Foundation

/// One line of a diff.
public struct DiffOp: Equatable, Sendable {
    public enum Kind: String, Sendable { case same, del, add }
    public var kind: Kind
    public var text: String
    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

/// A diff line, or a run of unchanged lines collapsed by `LineDiff.withContext`.
public enum DiffRow: Equatable, Sendable {
    case line(DiffOp)
    case skip(count: Int)
}

/// Line diff for version history and conflict resolution. Common leading and
/// trailing lines are trimmed first, then the changed middle is aligned by
/// longest common subsequence. Very large changed regions fall back to
/// "all removed, all added" rather than spending seconds aligning them.
public enum LineDiff {
    private static func lines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return jsSplit(normalized, "\n")
    }

    /// Operations turning `before` into `after`. Line endings are ignored.
    public static func diff(_ before: String, _ after: String, maxCells: Int = 4_000_000) -> [DiffOp] {
        // Intern lines by their exact bytes so comparisons are integer compares.
        var ids: [[UInt8]: Int] = [:]
        func intern(_ line: String) -> Int {
            let key = Array(line.utf8)
            if let id = ids[key] { return id }
            ids[key] = ids.count
            return ids.count - 1
        }
        let a = lines(before)
        let b = lines(after)
        let ia = a.map(intern)
        let ib = b.map(intern)

        var start = 0
        while start < a.count, start < b.count, ia[start] == ib[start] { start += 1 }
        var endA = a.count
        var endB = b.count
        while endA > start, endB > start, ia[endA - 1] == ib[endB - 1] { endA -= 1; endB -= 1 }

        var ops = a[..<start].map { DiffOp(.same, $0) }
        let midA = Array(a[start..<endA]), midB = Array(b[start..<endB])
        let ma = Array(ia[start..<endA]), mb = Array(ib[start..<endB])
        if midA.count * midB.count > maxCells {
            ops += midA.map { DiffOp(.del, $0) }
            ops += midB.map { DiffOp(.add, $0) }
        } else {
            let width = midB.count + 1
            var table = [UInt32](repeating: 0, count: (midA.count + 1) * width)
            var i = midA.count - 1
            while i >= 0 {
                var j = midB.count - 1
                while j >= 0 {
                    table[i * width + j] = ma[i] == mb[j]
                        ? table[(i + 1) * width + j + 1] + 1
                        : max(table[(i + 1) * width + j], table[i * width + j + 1])
                    j -= 1
                }
                i -= 1
            }
            var x = 0, y = 0
            while x < midA.count || y < midB.count {
                if x < midA.count, y < midB.count, ma[x] == mb[y] {
                    ops.append(DiffOp(.same, midA[x])); x += 1; y += 1
                } else if y >= midB.count || (x < midA.count && table[(x + 1) * width + y] >= table[x * width + y + 1]) {
                    ops.append(DiffOp(.del, midA[x])); x += 1
                } else {
                    ops.append(DiffOp(.add, midB[y])); y += 1
                }
            }
        }
        ops += a[endA...].map { DiffOp(.same, $0) }
        return ops
    }

    /// Counts of added and removed lines.
    public static func stats(_ ops: [DiffOp]) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for op in ops {
            if op.kind == .add { added += 1 } else if op.kind == .del { removed += 1 }
        }
        return (added, removed)
    }

    /// Changed lines with `context` unchanged lines around them; longer unchanged
    /// runs become `.skip(count:)`.
    public static func withContext(_ ops: [DiffOp], context: Int = 3) -> [DiffRow] {
        var near = [Bool](repeating: false, count: ops.count)
        for (index, op) in ops.enumerated() where op.kind != .same {
            for k in max(0, index - context)...min(ops.count - 1, index + context) { near[k] = true }
        }
        var out: [DiffRow] = []
        var skipped = 0
        for (index, op) in ops.enumerated() {
            if near[index] {
                if skipped > 0 { out.append(.skip(count: skipped)); skipped = 0 }
                out.append(.line(op))
            } else {
                skipped += 1
            }
        }
        if skipped > 0 { out.append(.skip(count: skipped)) }
        return out
    }
}
