import AppKit
import SwiftUI

@main
struct RewriteDBApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()
    @StateObject private var updater = Updater()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(state)
                .environmentObject(updater)
        } label: {
            MenuBarLabel()
                .environmentObject(state)
                .environmentObject(updater)
        }

        Window("RewriteDB Settings", id: "settings") {
            SettingsView()
                .environmentObject(state)
                .frame(width: 560, height: 640)
        }
        .windowResizability(.contentSize)

        Window("History", id: "history") {
            HistoryView()
                .environmentObject(state)
                .frame(minWidth: 680, minHeight: 440)
        }
        .windowResizability(.contentSize)

        Window("Welcome to RewriteDB", id: "onboarding") {
            OnboardingView()
                .environmentObject(state)
                .frame(width: 480, height: 560)
        }
        .windowResizability(.contentSize)

        Window("Software Update", id: "update") {
            UpdateView()
                .environmentObject(updater)
        }
        .windowResizability(.contentSize)
    }
}

/// The menu-bar status glyph: the Equalizer `WaveformIcon` rendered to a **template** `NSImage` so
/// AppKit tints it for light/dark menu bars and inverts it to white when the menu is open — which a
/// raw SwiftUI label does not do. Animation comes from the frame counters `AppState` already ticks.
struct MenuBarLabel: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var updater: Updater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let icon = iconState()
        Image(nsImage: Self.render(mode: icon.mode, frame: icon.frame))
            .accessibilityLabel(icon.label)
            .onAppear {                                // the label is present at launch
                maybeStartOnboarding()
                updater.checkOnLaunchIfDue()
            }
    }

    /// First launch: open the onboarding wizard for genuinely new users; silently mark an existing,
    /// already-configured install as onboarded so upgraders never see it.
    private func maybeStartOnboarding() {
        guard !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") else { return }
        if state.accessibilityTrusted && !state.effectiveProviderOrder().isEmpty {
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "onboarding")
    }

    private func iconState() -> (mode: WaveformIcon.Mode, frame: Int, label: String) {
        if state.isRecording { return (.recording, state.recordingFrame, "Recording") }
        if state.isWorking { return (.processing, state.spinnerFrame, "Working") }
        if state.showErrorFlash { return (.error, 0, "No text selected") }
        if state.needsSetup || state.dictationNeedsSetup { return (.setup, state.setupFrame, "Setup needed") }
        return (.idle, 0, "RewriteDB")
    }

    /// Rasterize the SwiftUI icon to a template NSImage. A fresh image each frame guarantees the
    /// menu-bar item repaints as the animation advances.
    @MainActor private static func render(mode: WaveformIcon.Mode, frame: Int) -> NSImage {
        let renderer = ImageRenderer(content: WaveformIcon(mode: mode, frame: frame).frame(width: 18, height: 18))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app (no Dock icon). LSUIElement in Info.plist handles this for the
        // bundled .app; set it here too so behavior is correct even when run unbundled.
        NSApp.setActivationPolicy(.accessory)

        // New users grant Accessibility inside the onboarding wizard, so don't double-prompt here;
        // existing (already-onboarded) users still get the system prompt if they've revoked it.
        if UserDefaults.standard.bool(forKey: "hasCompletedOnboarding"), !AccessibilityPermissions.isTrusted {
            AccessibilityPermissions.prompt()
        }
    }
}
