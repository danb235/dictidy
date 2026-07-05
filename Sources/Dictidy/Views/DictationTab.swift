import SwiftUI
import KeyboardShortcuts
import DictidyKit

struct DictationTab: View {
    @EnvironmentObject var state: AppState
    @State private var micGranted = MicrophonePermissions.isGranted
    @State private var reconfiguring = false

    /// Fully set up: model downloaded, mic granted, and at least one dictation shortcut bound.
    private var dictationReady: Bool {
        dictationModelReady && micGranted && hasAnyDictationShortcut
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Speak, transcribe on-device with Whisper, and paste at your cursor. "
                 + "“Dictate + Clean” also runs the transcript through your rewrite provider.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            if dictationReady && !reconfiguring {
                // Collapsed: one line once everything's set up.
                HStack {
                    StatusBadge(.ready, label: "Dictation ready")
                    Spacer()
                    Button("Reconfigure") { reconfiguring = true }
                }
            } else {
                steps
                if dictationReady {
                    Button("Done") { reconfiguring = false }
                }
            }

            Divider()

            // Always visible: which instruction cleans a "Dictate + Clean", and the tones toggle.
            Text("Cleanup instruction").font(.headline)
            Picker("Used by Dictate + Clean", selection: cleanupBinding) {
                ForEach(state.instructions) { instruction in
                    Text(instruction.name).tag(Optional(instruction.id))
                }
            }
            .pickerStyle(.menu)

            Toggle("Play start/stop sounds", isOn: $state.playDictationTones)

            Spacer()
        }
        .padding()
        .onAppear { micGranted = MicrophonePermissions.isGranted }
    }

    // MARK: - Stepped setup

    @ViewBuilder private var steps: some View {
        // Setup reads top-to-bottom: model → mic → shortcuts, each with a ✓ when done.
        stepHeader("1. Speech model", done: dictationModelReady)
        modelRow
        Text("Whisper large-v3-turbo (~1.6 GB), fully on-device — your audio never leaves your Mac.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Divider()

        // Microphone is granted in General → Permissions (the one place for permissions).
        stepHeader("2. Microphone", done: micGranted)
        if !micGranted {
            HStack(spacing: 10) {
                StatusBadge(.actionNeeded, label: "Not granted")
                Button("Grant in General…") { state.settingsTab = .general }
            }
        }

        Divider()

        stepHeader("3. Shortcuts", done: hasAnyDictationShortcut)
        KeyboardShortcuts.Recorder("Dictate (raw)", name: .init(ShortcutsRegistry.dictateName))
        KeyboardShortcuts.Recorder("Dictate + Clean", name: .init(ShortcutsRegistry.dictateAndCleanName))
        Text("Tap once to start, tap again to stop — the text pastes where your cursor is.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var modelRow: some View {
        switch state.modelStatus {
        case .ready:
            StatusBadge(.ready, label: "Downloaded")
        case .missing:
            Button("Download model (~1.6 GB)") { state.modelStore.download() }
                .buttonStyle(.borderedProminent)
        case .downloading(let progress):
            HStack(spacing: 10) {
                ProgressView(value: progress).frame(maxWidth: 220)
                Text("\(Int(progress * 100))%").font(.caption).monospacedDigit()
                Button("Cancel") { state.modelStore.cancel() }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).font(.callout).foregroundStyle(.orange)
                Button("Retry download") { state.modelStore.download() }
            }
        }
    }

    private func stepHeader(_ title: String, done: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.headline)
            if done { StatusBadge(.ready) }
        }
    }

    private var dictationModelReady: Bool {
        if case .ready = state.modelStatus { return true }
        return false
    }

    private var hasAnyDictationShortcut: Bool {
        state.shortcutDescription(forName: ShortcutsRegistry.dictateName) != nil
            || state.shortcutDescription(forName: ShortcutsRegistry.dictateAndCleanName) != nil
    }

    /// Reflects the effective cleanup instruction (falls back to Auto Clean) and persists changes.
    private var cleanupBinding: Binding<UUID?> {
        Binding(
            get: { state.dictationCleanupInstructionID ?? state.dictationCleanupInstruction?.id },
            set: { state.dictationCleanupInstructionID = $0 }
        )
    }
}
