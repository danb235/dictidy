import AppKit
import ApplicationServices
import CoreGraphics
import Carbon.HIToolbox

/// Performs the clipboard + synthetic-keystroke dance that replaces the user's
/// selection in place: copy the selection, hand the text to the caller, then paste
/// the rewritten result back over it.
@MainActor
final class RewriteService {
    static let shared = RewriteService()
    private init() {}

    struct PasteTarget {
        let application: NSRunningApplication
        let window: AXUIElement?
        let element: AXUIElement?
    }

    enum PasteError: LocalizedError {
        case targetUnavailable

        var errorDescription: String? {
            "Couldn't return to the text box. Click in it and choose Paste in the Dictidy menu again."
        }
    }

    /// Menu-bar menus leave the receiving app frontmost. Save its focused window and control before yielding.
    func capturePasteTarget() -> PasteTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        return PasteTarget(application: application,
                           window: Self.elementAttribute(kAXFocusedWindowAttribute, of: appElement),
                           element: Self.elementAttribute(kAXFocusedUIElementAttribute, of: appElement))
    }

    private static func elementAttribute(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func restoreFocus(to target: PasteTarget) async throws {
        // Let the menu finish closing before activating a window or sending keystrokes.
        try await Task.sleep(nanoseconds: 150_000_000)
        guard !target.application.isTerminated else { throw PasteError.targetUnavailable }
        if !target.application.isActive {
            guard target.application.activate(options: [.activateIgnoringOtherApps]) else {
                throw PasteError.targetUnavailable
            }
        }
        let deadline = Date().addingTimeInterval(1)
        while !target.application.isActive && Date() < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard target.application.isActive else { throw PasteError.targetUnavailable }
        if let window = target.window {
            let result = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            if result == .invalidUIElement { throw PasteError.targetUnavailable }
        }
        if let element = target.element {
            let result = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if result == .invalidUIElement { throw PasteError.targetUnavailable }
        }
        // Apps without focus-setting Accessibility support retain their own caret on activation.
        try await Task.sleep(nanoseconds: 60_000_000)
    }

    /// Remote desktop and screen sharing clients. They forward keystrokes to another machine
    /// immediately but sync the clipboard separately and later, so they need longer waits.
    private static let remoteDesktopBundleIDs: Set<String> = [
        "com.apple.ScreenSharing",
        "com.microsoft.rdc.macos",
        "com.microsoft.rdc.osx.beta",
        "com.p5sys.jump.mac.viewer",
        "com.edovia.screens.mac",
        "com.edovia.screens5.mac",
        "com.teamviewer.TeamViewer",
        "com.philandro.anydesk",
        "com.citrix.receiver.icaviewer.mac",
        "com.parsec.www",
        "com.realvnc.vncviewer",
    ]

    private var frontmostIsRemoteDesktop: Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return Self.remoteDesktopBundleIDs.contains(id)
    }

    /// Synthesizes ⌘C and returns the freshly-copied selection, or nil if nothing was selected.
    func captureSelection() async throws -> String? {
        let pasteboard = NSPasteboard.general
        let startCount = pasteboard.changeCount
        // A remote copy has to round trip back from the other machine before it lands here.
        let timeout: TimeInterval = frontmostIsRemoteDesktop ? 2.0 : 1.0

        await postCommandKey(CGKeyCode(kVK_ANSI_C))

        // Wait (briefly) for the copy to land on the pasteboard.
        let deadline = Date().addingTimeInterval(timeout)
        while pasteboard.changeCount == startCount && Date() < deadline {
            try await Task.sleep(nanoseconds: 30_000_000) // 30ms
        }

        guard pasteboard.changeCount != startCount else { return nil }
        let copied = pasteboard.string(forType: .string)
        return (copied?.isEmpty == false) ? copied : nil
    }

    /// Writes `text` to the pasteboard and synthesizes ⌘V to paste it over the selection.
    /// Optionally restores the previous clipboard contents afterward.
    /// `didPaste` runs right after ⌘V is sent, before any clipboard restore delay, so a caller can
    /// give feedback at the moment the text appears.
    func paste(_ text: String, restoreClipboard: Bool, to target: PasteTarget? = nil,
               didPaste: (() -> Void)? = nil) async throws {
        if let target { try await restoreFocus(to: target) }
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        // Remote clients sync the clipboard to the other machine after the fact, so give that sync
        // time to land before pasting, and far longer before swapping the old clipboard back.
        let remote = frontmostIsRemoteDesktop
        let settleDelay: UInt64 = remote ? 400_000_000 : 60_000_000
        let restoreDelay: UInt64 = remote ? 1_500_000_000 : 300_000_000

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Let the pasteboard write settle before pasting. If cancellation lands during this
        // window, restore the original clipboard even when normal clipboard restoration is off:
        // a cancelled operation must not leave behind text it never pasted.
        do {
            try await Task.sleep(nanoseconds: settleDelay)
            try Task.checkCancellation()
            if let target, !target.application.isActive { throw PasteError.targetUnavailable }
        } catch {
            pasteboard.clearContents()
            if let previous { pasteboard.setString(previous, forType: .string) }
            throw error
        }
        await postCommandKey(CGKeyCode(kVK_ANSI_V))
        didPaste?()

        if restoreClipboard {
            // Once Cmd-V has been posted, finish the clipboard handoff even if cancellation arrives;
            // restoring immediately can race the receiving app before it reads the pasteboard.
            try? await Task.sleep(nanoseconds: restoreDelay) // let the paste complete
            pasteboard.clearContents()
            if let previous {
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    /// Posts a full Command-modified keystroke: Command down, key down, key up, Command up.
    ///
    /// Setting `.maskCommand` on the key events alone is enough for local apps, but remote desktop
    /// clients track modifier state from the Command key's own events and would forward a bare
    /// letter. The modifier events keep their default flags: overwriting them drops the device
    /// bit that identifies which physical Command key is down.
    private func postCommandKey(_ key: CGKeyCode) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        let commandDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: true)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        keyUp?.flags = .maskCommand
        let commandUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: false)

        // Short gaps so clients that sample modifier state see Command held before the key arrives.
        let gap: UInt64 = 10_000_000 // 10ms
        commandDown?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: gap)
        keyDown?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: gap)
        keyUp?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: gap)
        commandUp?.post(tap: .cghidEventTap)
    }
}
