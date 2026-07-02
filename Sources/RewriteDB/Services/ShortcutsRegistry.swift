import Foundation
import KeyboardShortcuts
import RewriteDBKit

/// Binds each instruction's global keyboard shortcut to a trigger callback.
/// Shortcut names are derived from the instruction id, so they're stable across renames.
@MainActor
final class ShortcutsRegistry {
    /// Called (with the instruction id) when a registered shortcut fires.
    var onTrigger: ((UUID) -> Void)?
    /// Standalone dictation shortcuts (not tied to any instruction).
    var onDictate: (() -> Void)?
    var onDictateAndClean: (() -> Void)?

    /// Stable `KeyboardShortcuts.Name` keys for the two dictation actions.
    static let dictateName = "dictate"
    static let dictateAndCleanName = "dictate-and-clean"

    private var registered = Set<String>()
    private var registeredStandalone = false

    func sync(_ instructions: [Instruction]) {
        for instruction in instructions {
            let key = instruction.shortcutKey
            guard !registered.contains(key) else { continue }
            registered.insert(key)

            let id = instruction.id
            KeyboardShortcuts.onKeyUp(for: KeyboardShortcuts.Name(key)) { [weak self] in
                self?.onTrigger?(id)
            }
        }
    }

    /// Registers the two dictation shortcuts. Call once (idempotent) after `sync`.
    func registerStandalone() {
        guard !registeredStandalone else { return }
        registeredStandalone = true
        KeyboardShortcuts.onKeyUp(for: KeyboardShortcuts.Name(Self.dictateName)) { [weak self] in
            self?.onDictate?()
        }
        KeyboardShortcuts.onKeyUp(for: KeyboardShortcuts.Name(Self.dictateAndCleanName)) { [weak self] in
            self?.onDictateAndClean?()
        }
    }
}
