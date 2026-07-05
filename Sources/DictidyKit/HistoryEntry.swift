import Foundation

/// What produced a history entry.
/// - `rewrite`: selected text → Claude (before = selection, after = result).
/// - `dictationClean`: spoken → transcribed → Claude (before = transcript, after = cleaned).
/// - `dictation`: spoken → transcribed only (transcript in `after`, `before` empty, no Claude model).
public enum HistoryKind: String, Codable {
    case rewrite, dictation, dictationClean
}

/// One recorded transformation — a rewrite or a dictation — capturing the text so the user can
/// recover it if they later lose it. Immutable snapshot; entries are only created, viewed, copied,
/// or deleted.
public struct HistoryEntry: Identifiable, Codable, Equatable, Hashable {
    public let id: UUID
    public let date: Date
    public let kind: HistoryKind
    /// Instruction name for rewrite / dictation+clean; "Dictation" for a raw transcript.
    public let instructionName: String
    /// Claude model display name; empty for a raw dictation (no Claude call).
    public let model: String
    /// Empty for a raw dictation (there is no "before" — the transcript lives in `after`).
    public let before: String
    public let after: String

    public init(id: UUID = UUID(), date: Date = Date(), kind: HistoryKind = .rewrite,
                instructionName: String, model: String, before: String, after: String) {
        self.id = id
        self.date = date
        self.kind = kind
        self.instructionName = instructionName
        self.model = model
        self.before = before
        self.after = after
    }

    enum CodingKeys: String, CodingKey {
        case id, date, kind, instructionName, model, before, after
    }

    /// Custom decode so entries written before `kind` existed still load — they decode as `.rewrite`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        kind = try c.decodeIfPresent(HistoryKind.self, forKey: .kind) ?? .rewrite
        instructionName = try c.decode(String.self, forKey: .instructionName)
        model = try c.decode(String.self, forKey: .model)
        before = try c.decode(String.self, forKey: .before)
        after = try c.decode(String.self, forKey: .after)
    }
}

public extension Array where Element == HistoryEntry {
    /// Newest-first list with `entry` prepended and trimmed to `limit`. Pure — no file system,
    /// no `@MainActor` — so the cap logic is unit-testable on its own.
    func prepending(_ entry: HistoryEntry, cappedTo limit: Int) -> [HistoryEntry] {
        Array(([entry] + self).prefix(limit))
    }
}
