import AppKit
import SwiftUI

@main
struct RewriteDBApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(state)
        } label: {
            if state.isWorking {
                // Stepped rotation: each spinnerFrame change re-renders the menu-bar image,
                // so the circular-arrows icon visibly spins until the rewrite completes.
                Image(systemName: "arrow.triangle.2.circlepath")
                    .rotationEffect(.degrees(Double(state.spinnerFrame) * 30))
            } else if state.showErrorFlash {
                // Transient "operation not possible" signal after a no-selection trigger.
                Image(systemName: "nosign")
            } else if state.needsSetup {
                // Draws attention until setup is complete; the menu explains what's missing.
                Image(systemName: "exclamationmark.triangle.fill")
            } else {
                // "Aa" letters glyph — fits a text-rewriting tool.
                Image(systemName: "textformat")
            }
        }

        Window("RewriteDB Settings", id: "settings") {
            SettingsView()
                .environmentObject(state)
                .frame(width: 560, height: 640)
        }
        .windowResizability(.contentSize)

        Window("Rewrite History", id: "history") {
            HistoryView()
                .environmentObject(state)
                .frame(minWidth: 680, minHeight: 440)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app (no Dock icon). LSUIElement in Info.plist handles this for the
        // bundled .app; set it here too so behavior is correct even when run unbundled.
        NSApp.setActivationPolicy(.accessory)

        if !AccessibilityPermissions.isTrusted {
            AccessibilityPermissions.prompt()
        }
    }
}
