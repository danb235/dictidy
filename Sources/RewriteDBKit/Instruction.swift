import Foundation

/// A named rewrite "instruction" — the system prompt that tells Claude how to transform
/// the selected text. Each instruction can be bound to its own global keyboard shortcut.
public struct Instruction: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var systemPrompt: String

    public init(id: UUID = UUID(), name: String, systemPrompt: String) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
    }

    /// Stable key used to derive this instruction's `KeyboardShortcuts.Name`.
    /// Derived from the id so renaming never breaks the bound shortcut.
    public var shortcutKey: String { "instruction-\(id.uuidString)" }
}

extension Instruction {
    /// Seeded on first launch. "Auto Clean" is bound to ⌃⌘R by default (see AppState).
    public static let defaults: [Instruction] = [
        Instruction(
            name: "Auto Clean",
            systemPrompt: """
            You rewrite messy dictated text into clean, clear writing that reads as if the person had typed it carefully and thought it through. The input comes from speech-to-text, so it contains filler words, false starts, repeated ideas, and far too many commas. Your job is to fix all of that.

            Rules:

            Output only the rewritten text. Do not add comments, explanations, preambles, or your own questions. Do not respond to the content; just rewrite it.

            Fix grammar, spelling, and punctuation. Remove filler and verbal tics such as "so", "like", "basically", "yeah", "of course", "you know", and "I mean" when they add nothing.

            Use as little punctuation as possible while keeping sentences correct and easy to read. Strip the excess commas that dictation adds.

            When a sentence is a question, end it with a question mark. Judge by intent, not pauses: phrasings like "do you understand", "right", "what do you think", "does that make sense" are questions even when the speaker did not pause clearly.

            Break run-on speech into clear, well-structured sentences. You may reorder or merge ideas when it improves flow, but never add information that is not there and never drop the speaker's meaning.

            Keep the tone personal and the language simple and direct. Write the way the speaker would if they had typed it well.

            Never use dashes of any kind.

            Keep the text in its original language.
            """
        ),
        Instruction(
            name: "Formal",
            systemPrompt: """
            Rewrite the text in a professional, formal tone suitable for business communication. \
            Keep the meaning intact. Output only the rewritten text, with no preamble or explanation.
            """
        ),
        Instruction(
            name: "Friendly",
            systemPrompt: """
            Rewrite the text in a warm, friendly, conversational tone while keeping the meaning \
            intact. Output only the rewritten text, with no preamble or explanation.
            """
        ),
        Instruction(
            name: "Translate to English",
            systemPrompt: """
            Translate the text into natural, fluent English. If it is already English, improve \
            clarity and fix errors. Output only the translated text, with no preamble or explanation.
            """
        )
    ]
}
