import AppKit
import CoreGraphics
import Carbon.HIToolbox

/// Performs the clipboard + synthetic-keystroke dance that replaces the user's
/// selection in place: copy the selection, hand the text to the caller, then paste
/// the rewritten result back over it.
@MainActor
final class RewriteService {
    static let shared = RewriteService()
    private init() {}

    /// Synthesizes ⌘C and returns the freshly-copied selection, or nil if nothing was selected.
    func captureSelection() async throws -> String? {
        let pasteboard = NSPasteboard.general
        let startCount = pasteboard.changeCount

        postCommandKey(CGKeyCode(kVK_ANSI_C))

        // Wait (briefly) for the copy to land on the pasteboard.
        let deadline = Date().addingTimeInterval(1.0)
        while pasteboard.changeCount == startCount && Date() < deadline {
            try await Task.sleep(nanoseconds: 30_000_000) // 30ms
        }

        guard pasteboard.changeCount != startCount else { return nil }
        let copied = pasteboard.string(forType: .string)
        return (copied?.isEmpty == false) ? copied : nil
    }

    /// Writes `text` to the pasteboard and synthesizes ⌘V to paste it over the selection.
    /// Optionally restores the previous clipboard contents afterward.
    func paste(_ text: String, restoreClipboard: Bool) async throws {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Let the pasteboard write settle before pasting. If cancellation lands during this
        // window, restore the original clipboard even when normal clipboard restoration is off:
        // a cancelled operation must not leave behind text it never pasted.
        do {
            try await Task.sleep(nanoseconds: 60_000_000) // 60ms
            try Task.checkCancellation()
        } catch {
            pasteboard.clearContents()
            if let previous { pasteboard.setString(previous, forType: .string) }
            throw error
        }
        postCommandKey(CGKeyCode(kVK_ANSI_V))

        if restoreClipboard {
            // Once Cmd-V has been posted, finish the clipboard handoff even if cancellation arrives;
            // restoring immediately can race the receiving app before it reads the pasteboard.
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms — let the paste complete
            pasteboard.clearContents()
            if let previous {
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    /// Posts a Command-modified key down+up via a synthetic event tap.
    private func postCommandKey(_ key: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
