import Foundation

/// A one-line, quoted excerpt of `text` for the menu-bar menu, so the user can see what Copy Last
/// Text and Paste Last Text will use. Whitespace and line breaks collapse to single spaces. Text longer
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
