import Foundation

/// One recorded rewrite: the text before (the captured selection) and after (Claude's result),
/// so the user can recover either if they later lose it. Immutable snapshot — entries are never
/// edited, only created, viewed, copied, or deleted.
public struct HistoryEntry: Identifiable, Codable, Equatable, Hashable {
    public let id: UUID
    public let date: Date
    public let instructionName: String
    /// Model display name captured at rewrite time; falls back to the model id.
    public let model: String
    public let before: String
    public let after: String

    public init(id: UUID = UUID(), date: Date = Date(), instructionName: String,
                model: String, before: String, after: String) {
        self.id = id
        self.date = date
        self.instructionName = instructionName
        self.model = model
        self.before = before
        self.after = after
    }
}

public extension Array where Element == HistoryEntry {
    /// Newest-first list with `entry` prepended and trimmed to `limit`. Pure — no file system,
    /// no `@MainActor` — so the cap logic is unit-testable on its own.
    func prepending(_ entry: HistoryEntry, cappedTo limit: Int) -> [HistoryEntry] {
        Array(([entry] + self).prefix(limit))
    }
}
