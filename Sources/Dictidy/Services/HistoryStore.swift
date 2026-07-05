import Foundation
import DictidyKit

/// Persists the rewrite history as a JSON file in Application Support. A file (not UserDefaults)
/// keeps the potentially-large before/after text out of the preferences plist. All operations are
/// best-effort: a missing or corrupt file yields an empty history rather than an error, so history
/// storage can never block or crash a rewrite.
enum HistoryStore {
    private static var fileURL: URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        let folder = dir.appendingPathComponent("Dictidy", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("history.json")
    }

    /// Loads saved entries, or `[]` if the file is missing, empty, or unreadable.
    static func load() -> [HistoryEntry] {
        guard let url = fileURL, let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    /// Atomically writes the entries (temp-then-rename, so a crash never truncates the file).
    static func save(_ entries: [HistoryEntry]) {
        guard let url = fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(entries).write(to: url, options: .atomic)
    }
}
