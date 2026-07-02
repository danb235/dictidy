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
            if state.isRecording {
                // Listening: the mic "breathes" (opacity pulse driven by recordingFrame) so you
                // know it's live and can start talking. Stepped animation — macOS 13 safe.
                Image(systemName: "mic.fill")
                    .opacity(recordingPulse(state.recordingFrame))
            } else if state.isWorking {
                // Processing: stepped rotation re-renders each spinnerFrame while transcribing /
                // rewriting, so you know you've stopped and it's working.
                Image(systemName: "arrow.triangle.2.circlepath")
                    .rotationEffect(.degrees(Double(state.spinnerFrame) * 30))
            } else if state.showErrorFlash {
                // Transient "operation not possible" signal after a no-selection trigger.
                Image(systemName: "nosign")
            } else if state.needsSetup || state.dictationNeedsSetup {
                // Draws attention until setup is complete; the menu explains what's missing
                // (rewrite setup always; dictation setup only once the user has engaged with it).
                Image(systemName: "exclamationmark.triangle.fill")
            } else {
                // Idle: a speech-bubble-with-text — "produce polished text," voice or typed.
                // Distinct from the recording mic and the processing spinner.
                Image(systemName: "text.bubble")
            }
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
    }
}

/// Smooth 0.4↔1.0 "breathe" for the listening mic, driven by the recording frame counter.
/// A triangle wave (no `symbolEffect`, which is macOS 14+), so it animates on the macOS 13 target.
private func recordingPulse(_ frame: Int) -> Double {
    let period = 16.0
    let phase = Double(frame).truncatingRemainder(dividingBy: period) / period   // 0..<1
    let triangle = 1.0 - abs(2.0 * phase - 1.0)                                   // 0→1→0
    return 0.4 + 0.6 * triangle
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
