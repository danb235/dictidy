import Foundation
import KeyboardShortcuts
import RewriteDBKit

/// Binds each instruction's global keyboard shortcut to a trigger callback.
/// Shortcut names are derived from the instruction id, so they're stable across renames.
@MainActor
final class ShortcutsRegistry {
    /// Called (with the instruction id) when a registered shortcut fires.
    var onTrigger: ((UUID) -> Void)?

    private var registered = Set<String>()

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
}
