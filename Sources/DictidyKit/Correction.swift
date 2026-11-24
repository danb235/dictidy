import Foundation

/// A word or phrase that speech recognition keeps getting wrong, and how it should be written.
/// The user's list is applied three ways: the correct spellings are offered to Whisper as a hint,
/// dictated transcripts get an exact whole-word replacement, and every rewrite prompt includes the list.
public struct Correction: Identifiable, Codable, Equatable {
    public var id: UUID
    public var heard: String
    public var replacement: String

    public init(id: UUID = UUID(), heard: String, replacement: String) {
        self.id = id
        self.heard = heard
        self.replacement = replacement
    }

    var isComplete: Bool {
        !heard.trimmingCharacters(in: .whitespaces).isEmpty
            && !replacement.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

public enum Corrections {

    /// Reads a pasted list, one correction per line, such as "Scott → Scot", "VJ -> Vijay", or
    /// "Furman - > Fermin". Leading list bullets are ignored, as are lines without both sides.
    public static func parse(_ text: String) -> [Correction] {
        let separator = try! NSRegularExpression(pattern: "→|-\\s*>|=>|>")
        return text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            for bullet in ["* ", "- ", "• "] where line.hasPrefix(bullet) {
                line = String(line.dropFirst(bullet.count))
            }
            let ns = line as NSString
            guard let match = separator.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
                return nil
            }
            let correction = Correction(
                heard: ns.substring(to: match.range.location).trimmingCharacters(in: .whitespaces),
                replacement: ns.substring(from: NSMaxRange(match.range)).trimmingCharacters(in: .whitespaces))
            return correction.isComplete ? correction : nil
        }
    }

    /// Adds `new` to `existing`. An entry for a word already in the list replaces it in place.
    public static func merge(_ new: [Correction], into existing: [Correction]) -> [Correction] {
        var result = existing
        for correction in new {
            if let index = result.firstIndex(where: { $0.heard.lowercased() == correction.heard.lowercased() }) {
                result[index].replacement = correction.replacement
            } else {
                result.append(correction)
            }
        }
        return result
    }

    /// Replaces each heard word or phrase, as a whole word and ignoring case, with its correction.
    /// Used on dictated transcripts only. Typed text is left to the rewrite prompt.
    public static func apply(_ corrections: [Correction], to text: String) -> String {
        corrections.filter(\.isComplete).reduce(text) { text, correction in
            let heard = NSRegularExpression.escapedPattern(for: correction.heard.trimmingCharacters(in: .whitespaces))
            let pattern = "(?<![\\p{L}\\p{N}])" + heard + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
            let template = NSRegularExpression.escapedTemplate(
                for: correction.replacement.trimmingCharacters(in: .whitespaces))
            return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                  withTemplate: template)
        }
    }

    /// The correct spellings as a Whisper hint, which nudges recognition toward them.
    public static func whisperHint(_ corrections: [Correction]) -> String? {
        var seen = Set<String>()
        let words = corrections.filter(\.isComplete)
            .map { $0.replacement.trimmingCharacters(in: .whitespaces) }
            .filter { seen.insert($0.lowercased()).inserted }
        return words.isEmpty ? nil : "Glossary: " + words.joined(separator: ", ") + "."
    }

    /// The list as a section of the rewrite system prompt.
    public static func promptSection(_ corrections: [Correction]) -> String? {
        let lines = corrections.filter(\.isComplete).map {
            "- \($0.heard.trimmingCharacters(in: .whitespaces)) → \($0.replacement.trimmingCharacters(in: .whitespaces))"
        }
        guard !lines.isEmpty else { return nil }
        return "Apply these corrections. Wherever the text contains the word or phrase on the left, "
            + "write the one on the right instead:\n" + lines.joined(separator: "\n")
    }
}
