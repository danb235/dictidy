import SwiftUI
import RewriteDBKit

struct MenuBarContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if state.isRecording {
            Text("● Recording… — press the shortcut again to stop")
            Divider()
        } else if state.isWorking {
            Text(state.statusMessage ?? "Working…")
            Divider()
        }

        // Setup checklist: only the missing steps, each a one-click fix. Rewrite steps always
        // (core); dictation steps only once the user has engaged with dictation (no nagging).
        if state.needsSetup || state.dictationNeedsSetup {
            if state.needsSetup {
                Text("⚠︎ To rewrite text")
                if !state.accessibilityTrusted {
                    Button("Grant Accessibility access…") {
                        AccessibilityPermissions.openSettings()
                    }
                    Text("…enable RewriteDB, then quit and relaunch")
                }
                if state.effectiveProviderOrder().isEmpty {
                    Button("Set up rewriting…") { openSettings(.rewrite) }
                }
            }
            if state.dictationNeedsSetup {
                Text("⚠︎ To dictate")
                if !dictationModelReady {
                    Button("Download speech model…") { openSettings(.dictation) }
                }
                if !MicrophonePermissions.isGranted {
                    Button("Grant Microphone access…") { MicrophonePermissions.openSettings() }
                }
            }
            Divider()
        }

        // Instructions — each shows its bound shortcut (or that none is set).
        if state.instructions.isEmpty {
            Text("No instructions yet")
        } else {
            ForEach(state.instructions) { instruction in
                Button(menuTitle(for: instruction)) {
                    Task { await state.runRewrite(instruction: instruction) }
                }
                .disabled(state.isWorking)
            }
        }

        Divider()

        // Dictation. Actions when the model is ready; a quiet setup link for new users; nothing
        // here while dictation is mid-setup (the "To dictate" checklist above shows the fix).
        if state.isRecording {
            Button("Stop Dictation") { state.stopAndProcess() }
            Divider()
        } else if dictationModelReady {
            Button(dictateTitle) { state.toggleDictation(mode: .raw) }
                .disabled(state.isWorking)
            Button(dictateAndCleanTitle) { state.toggleDictation(mode: .clean) }
                .disabled(state.isWorking)
            Divider()
        } else if !state.dictationEngaged {
            Button("Set up dictation…") { openSettings(.dictation) }
            Divider()
        }

        Button("History…") { openHistory() }

        Button("Settings…") { openSettings(.rewrite) }
            .keyboardShortcut(",", modifiers: .command)

        Button("Quit RewriteDB") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    private func menuTitle(for instruction: Instruction) -> String {
        if let shortcut = state.shortcutDescription(for: instruction) {
            return "\(instruction.name)  \(shortcut)"
        }
        return "\(instruction.name)  (no shortcut set)"
    }

    private var dictateTitle: String {
        if let s = state.shortcutDescription(forName: ShortcutsRegistry.dictateName) { return "Dictate  \(s)" }
        return "Dictate  (no shortcut set)"
    }

    private var dictateAndCleanTitle: String {
        if let s = state.shortcutDescription(forName: ShortcutsRegistry.dictateAndCleanName) { return "Dictate + Clean  \(s)" }
        return "Dictate + Clean  (no shortcut set)"
    }

    private var dictationModelReady: Bool {
        if case .ready = state.modelStatus { return true }
        return false
    }

    private func openSettings(_ tab: SettingsTab) {
        state.settingsTab = tab
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
    }

    private func openHistory() {
        // Accessory (menu-bar) apps can open windows behind others — activate first so it fronts.
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "history")
    }
}
