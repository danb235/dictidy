import Foundation

/// A one-line, quoted excerpt of `text` for the menu-bar menu, where it labels the Paste and Copy
/// actions for the latest output. Whitespace and line breaks collapse to single spaces. Text longer
/// than `limit` characters is cut, preferably at a word boundary, and ends with an ellipsis. Counts
/// `Character`s, so emoji and accented letters are never split. Returns nil when there is nothing to show.
public func menuPreview(_ text: String, limit: Int = 45) -> String? {
    let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    guard !collapsed.isEmpty else { return nil }
    let limit = max(limit, 1)
    guard collapsed.count > limit else { return "“\(collapsed)”" }

    var cut = String(collapsed.prefix(limit))
    // Back up to the last space when it is close to the end, so the preview doesn't end mid-word.
    if let space = cut.lastIndex(of: " "), cut.distance(from: space, to: cut.endIndex) <= 15 {
        cut = String(cut[..<space])
    }
    // Drop trailing separators so the ellipsis reads cleanly ("send the…", not "send the,…").
    let trimmed = String(cut.reversed().drop(while: { $0.isWhitespace || ",;:-".contains($0) }).reversed())
    return "“\(trimmed.isEmpty ? cut : trimmed)…”"
}

/// The full text for a menu item's hover tooltip, so the user can read what the one-line preview cuts
/// off. Line breaks are kept (tooltips wrap and show them), runs of blank lines shrink to one, and the
/// ends are trimmed. Very long text is capped at `limit` characters, preferably at a word boundary,
/// with a note of how much was left out, so a long dictation can't produce a screen-filling tooltip.
public func menuTooltip(_ text: String, limit: Int = 1_000) -> String? {
    var lines: [Substring] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let isBlank = line.allSatisfy(\.isWhitespace)
        if isBlank, lines.last?.allSatisfy(\.isWhitespace) ?? true { continue }
        lines.append(isBlank ? "" : line)
    }
    let cleaned = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return nil }
    let limit = max(limit, 1)
    guard cleaned.count > limit else { return cleaned }

    var cut = String(cleaned.prefix(limit))
    if let space = cut.lastIndex(where: \.isWhitespace), cut.distance(from: space, to: cut.endIndex) <= 40 {
        cut = String(cut[..<space])
    }
    cut = cut.trimmingCharacters(in: .whitespacesAndNewlines)
    let omitted = cleaned.count - cut.count
    return "\(cut)…\n\n(\(omitted.formatted()) more \(omitted == 1 ? "character" : "characters"))"
}
