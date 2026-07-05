import AVFoundation
import AppKit

/// Thin wrapper over microphone (TCC) authorization, mirroring `AccessibilityPermissions`.
/// Requires `NSMicrophoneUsageDescription` in Info.plist; the first `request` shows the prompt.
enum MicrophonePermissions {
    static var status: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static var isGranted: Bool { status == .authorized }

    /// Prompts on first use; completion is delivered on the main actor.
    static func request(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
