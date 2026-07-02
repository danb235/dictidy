import Foundation

public enum DiffKind: Equatable { case equal, deleted, inserted }

/// A run of text tagged with how it changed between two strings.
public struct DiffToken: Equatable {
    public let text: String
    public let kind: DiffKind
    public init(text: String, kind: DiffKind) { self.text = text; self.kind = kind }
}

/// Word-level diff between two strings, via a longest-common-subsequence over tokens (runs of
/// non-whitespace and whitespace, both preserved so the text reconstructs exactly). Pure and
/// dependency-free so it's unit-testable; the History view styles the result.
///
/// Invariant: joining tokens where `kind != .inserted` yields `before`; joining tokens where
/// `kind != .deleted` yields `after`.
public enum WordDiff {
    public static func diff(before: String, after: String) -> [DiffToken] {
        let a = tokenize(before)
        let b = tokenize(after)
        let n = a.count, m = b.count
        guard n > 0 || m > 0 else { return [] }

        // lcs[i][j] = LCS length of a[i...] and b[j...].
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        var out: [DiffToken] = []
        func append(_ text: String, _ kind: DiffKind) {
            if let last = out.last, last.kind == kind {                     // merge adjacent same-kind runs
                out[out.count - 1] = DiffToken(text: last.text + text, kind: kind)
            } else {
                out.append(DiffToken(text: text, kind: kind))
            }
        }

        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] { append(a[i], .equal); i += 1; j += 1 }
            else if lcs[i + 1][j] >= lcs[i][j + 1] { append(a[i], .deleted); i += 1 }
            else { append(b[j], .inserted); j += 1 }
        }
        while i < n { append(a[i], .deleted); i += 1 }
        while j < m { append(b[j], .inserted); j += 1 }
        return out
    }

    /// Split into alternating runs of whitespace and non-whitespace, preserving both.
    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentIsSpace: Bool?
        for ch in s {
            let isSpace = ch.isWhitespace
            if currentIsSpace == nil || isSpace == currentIsSpace {
                current.append(ch)
            } else {
                tokens.append(current); current = String(ch)
            }
            currentIsSpace = isSpace
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
