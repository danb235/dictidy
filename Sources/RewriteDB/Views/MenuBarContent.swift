import SwiftUI
import RewriteDBKit

struct MenuBarContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if state.isWorking {
            Text(state.statusMessage ?? "Rewriting…")
            Divider()
        }

        // Setup checklist: shows only the steps that are still missing, each a one-click fix.
        if state.needsSetup {
            Text("⚠︎ Finish setup to enable rewriting")
            if !state.accessibilityTrusted {
                Button("Grant Accessibility access…") {
                    AccessibilityPermissions.openSettings()
                }
                Text("…enable RewriteDB, then quit and relaunch")
            }
            if !state.hasAPIKey {
                Button("Add your API key…") { openSettings(.apiKey) }
            }
            if state.selectedModelID.isEmpty {
                Button("Choose a model…") { openSettings(.model) }
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

        Button("History…") { openHistory() }

        Button("Settings…") { openSettings(.apiKey) }
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
