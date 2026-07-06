import SwiftUI
import KeyboardShortcuts

// First-run onboarding wizard for Dictidy.
//
// One guided window that takes a brand-new user from install to fully working. Dictidy has two
// equally first-class features — dictation and rewrite — so the wizard gives each its own screen,
// with the same "set it up now, or turn it on later" treatment and the same live-gated setup. There
// is no bias toward either feature, and nothing is framed as "optional".
//
// Flow: Welcome → Dictation → Rewrite → Permissions → Done.
//   • Dictation: enable, then download the speech model right there (Continue waits for it).
//   • Rewrite: enable, then add a Claude API key and/or download the on-device model (Continue waits).
//   • Permissions: grant exactly what the enabled features need (Accessibility for either; Microphone
//     for dictation). Every check is verified live — Continue stays disabled until it actually passes.
//
// Reuses the app's services: AccessibilityPermissions, MicrophonePermissions, KeychainService,
// AppState (saveAPIKey / refreshModels / modelStore / localModelStore / status), KeyboardShortcuts,
// and the shared StatusBadge / StatusRow / DownloadRow.

// MARK: - Steps

enum OnboardingStep: Hashable { case welcome, dictation, rewrite, permissions, done }

// MARK: - Model

@MainActor
final class OnboardingModel: ObservableObject {
    private let defaults = UserDefaults.standard
    private enum Keys {
        static let index = "onboarding.index"
        static let dictation = "onboarding.dictationEnabled"
        static let rewrite = "onboarding.rewriteEnabled"
        static let useClaude = "onboarding.rewriteUseClaude"
        static let useLocal = "onboarding.rewriteUseLocal"
    }

    /// Default dictation shortcuts seeded on finish if the user enables dictation and hasn't set them:
    /// Dictate + Clean on Control-Space, raw Dictate on Option-Space.
    static let defaultDictateCleanShortcut = "⌃Space"
    static let defaultDictateShortcut = "⌥Space"

    @Published var index = 0 { didSet { defaults.set(index, forKey: Keys.index) } }

    // Each feature is enabled by default and set up on its own screen — no "optional" framing.
    @Published var dictationEnabled = true { didSet { defaults.set(dictationEnabled, forKey: Keys.dictation) } }
    @Published var rewriteEnabled = true   { didSet { defaults.set(rewriteEnabled, forKey: Keys.rewrite) } }
    // How rewriting runs: a Claude API key, the on-device model, or both.
    @Published var rewriteUseClaude = true { didSet { defaults.set(rewriteUseClaude, forKey: Keys.useClaude) } }
    @Published var rewriteUseLocal = false { didSet { defaults.set(rewriteUseLocal, forKey: Keys.useLocal) } }

    // Live-verified permission state (polled).
    @Published var accessibilityGranted = AccessibilityPermissions.isTrusted
    @Published var micGranted = MicrophonePermissions.isGranted

    private var timer: Timer?

    init() {
        // Resume where a previous session left off (e.g. after granting Accessibility, which can
        // require a relaunch; the wizard reopens on the same step with its check now passing).
        index = defaults.integer(forKey: Keys.index)
        if defaults.object(forKey: Keys.dictation) != nil { dictationEnabled = defaults.bool(forKey: Keys.dictation) }
        if defaults.object(forKey: Keys.rewrite) != nil   { rewriteEnabled = defaults.bool(forKey: Keys.rewrite) }
        if defaults.object(forKey: Keys.useClaude) != nil { rewriteUseClaude = defaults.bool(forKey: Keys.useClaude) }
        if defaults.object(forKey: Keys.useLocal) != nil  { rewriteUseLocal = defaults.bool(forKey: Keys.useLocal) }
    }

    let steps: [OnboardingStep] = [.welcome, .dictation, .rewrite, .permissions, .done]
    var step: OnboardingStep { steps[min(index, steps.count - 1)] }
    var isFirst: Bool { index == 0 }
    var isLast: Bool { step == .done }

    func next() { if index < steps.count - 1 { index += 1 } }
    func back() { if index > 0 { index -= 1 } }

    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.accessibilityGranted = AccessibilityPermissions.isTrusted
                self?.micGranted = MicrophonePermissions.isGranted
            }
        }
    }
    func stopPolling() { timer?.invalidate(); timer = nil }

    func finish(_ state: AppState) {
        // Persist the rewrite provider strategy from the chosen paths.
        if rewriteEnabled {
            switch (rewriteUseClaude, rewriteUseLocal) {
            case (true, true):   state.rewriteProvider = .anthropic; state.fallbackEnabled = true
            case (true, false):  state.rewriteProvider = .anthropic; state.fallbackEnabled = false
            case (false, true):  state.rewriteProvider = .local;     state.fallbackEnabled = false
            case (false, false): break   // nothing chosen; leave existing defaults
            }
        }
        // Dictation shortcut: seed a working default if enabled and none is bound; clear if disabled,
        // so the app's dictation-engaged state reflects the user's choice.
        let dictate = KeyboardShortcuts.Name(ShortcutsRegistry.dictateName)
        let dictateClean = KeyboardShortcuts.Name(ShortcutsRegistry.dictateAndCleanName)
        if dictationEnabled {
            let bound = KeyboardShortcuts.getShortcut(for: dictate) != nil
                || KeyboardShortcuts.getShortcut(for: dictateClean) != nil
            if !bound {
                // Dictate + Clean on Control-Space; raw Dictate on Option-Space.
                KeyboardShortcuts.setShortcut(.init(.space, modifiers: [.control]), for: dictateClean)
                KeyboardShortcuts.setShortcut(.init(.space, modifiers: [.option]), for: dictate)
            }
        } else {
            KeyboardShortcuts.setShortcut(nil, for: dictate)
            KeyboardShortcuts.setShortcut(nil, for: dictateClean)
        }
        defaults.set(true, forKey: "hasCompletedOnboarding")
        [Keys.index, Keys.dictation, Keys.rewrite, Keys.useClaude, Keys.useLocal].forEach { defaults.removeObject(forKey: $0) }
        stopPolling()
    }
}

private func isReady(_ status: ModelStatus) -> Bool { if case .ready = status { return true }; return false }

// MARK: - Root view

struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = OnboardingModel()

    var body: some View {
        VStack(spacing: 0) {
            // Scrollable so a step with a key field plus two model downloads never clips.
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 34).padding(.top, 30).padding(.bottom, 10)
            }
            if model.step != .welcome && model.step != .done { ProgressDots(model: model).padding(.top, 4) }
            footer.padding(24)
        }
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome:     WelcomeStep()
        case .dictation:   DictationStep(model: model)
        case .rewrite:     RewriteStep(model: model)
        case .permissions: PermissionsStep(model: model)
        case .done:        DoneStep(model: model)
        }
    }

    private var footer: some View {
        HStack {
            if !model.isFirst && !model.isLast {
                Button("Back") { model.back() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Spacer()
            Button(primaryTitle) {
                if model.isLast { model.finish(state); dismiss() } else { model.next() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canContinue)
        }
    }

    private var primaryTitle: String {
        switch model.step { case .welcome: "Get started"; case .done: "Start using Dictidy"; default: "Continue" }
    }

    /// The live gate: you cannot pass a step until its requirement is actually satisfied.
    private var canContinue: Bool {
        switch model.step {
        case .welcome, .done:
            return true
        case .dictation:
            // If dictation is on, the speech model must be downloaded before moving on.
            return !model.dictationEnabled || isReady(state.modelStatus)
        case .rewrite:
            guard model.rewriteEnabled else { return true }
            let atLeastOne = model.rewriteUseClaude || model.rewriteUseLocal
            let claudeOK = !model.rewriteUseClaude || state.anthropicReady
            let localOK  = !model.rewriteUseLocal  || state.localModelReady
            return atLeastOne && claudeOK && localOK
        case .permissions:
            let needAccessibility = model.dictationEnabled || model.rewriteEnabled
            let needMic = model.dictationEnabled
            return (!needAccessibility || model.accessibilityGranted) && (!needMic || model.micGranted)
        }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 16) {
            WaveformIcon(mode: .idle)
                .frame(width: 44, height: 44)
                .padding(20)
                .background(LinearGradient(colors: [.blue, .indigo], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 20))
                .foregroundStyle(.white)
            Text("Welcome to Dictidy").font(.title).bold()
            Text("Dictidy does two things from a single keystroke: dictate by voice, and rewrite text you have already written. Let's set up both. It takes about a minute.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, minHeight: 430)
    }
}

private struct DictationStep: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepTitle("Dictation", "Speak anywhere and Dictidy drops in clean, finished text. Speech runs entirely on your Mac with Whisper, so your audio never leaves the device.")

            Toggle(isOn: $model.dictationEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up dictation").fontWeight(.semibold)
                    Text("Turn speech into finished text with a keystroke.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if model.dictationEnabled {
                Divider()
                Text("Speech model").fontWeight(.semibold)
                DownloadRow(status: state.modelStatus,
                            sizeNote: "Whisper large-v3-turbo · about 1.6 GB · a one-time download that runs on your Mac",
                            download: { state.modelStore.download() },
                            cancel:   { state.modelStore.cancel() })
                Text("Dictate and Clean runs on \(OnboardingModel.defaultDictateCleanShortcut), and raw Dictate on \(OnboardingModel.defaultDictateShortcut). You can change both in Settings, under Dictation.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Dictation stays off for now. It is a core part of Dictidy, and you can turn it on anytime in Settings.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct RewriteStep: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var model: OnboardingModel
    @State private var key = KeychainService.load() ?? ""
    @State private var refreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepTitle("Rewrite", "Select any text and Dictidy rewrites it in place. Fix grammar, change the tone, or tighten it, in any app.")

            Toggle(isOn: $model.rewriteEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up rewriting").fontWeight(.semibold)
                    Text("Rephrase or clean up text you have already written.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if model.rewriteEnabled {
                Divider()
                Text("Choose how rewriting runs. Use a Claude API key, the on-device model, or both.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: $model.rewriteUseClaude) { Text("Use my Claude API key").fontWeight(.medium) }
                if model.rewriteUseClaude {
                    HStack {
                        SecureField("sk-ant-…", text: $key).textFieldStyle(.roundedBorder)
                        Button("Save") {
                            state.saveAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines))
                            refreshing = true
                            Task { await state.refreshModels(); refreshing = false }
                        }.disabled(key.isEmpty)
                    }
                    if refreshing {
                        StatusBadge(.working, label: "Validating…")
                    } else if state.anthropicReady {
                        StatusBadge(.ready, label: "Valid key · \(state.models.count) models")
                        Picker("Model", selection: $state.selectedModelID) {
                            ForEach(state.models.sortedByDisplayName()) { Text($0.displayName).tag($0.id) }
                        }.pickerStyle(.menu)
                    } else {
                        Link("Get a key ↗", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                            .font(.callout)
                    }
                }

                Toggle(isOn: $model.rewriteUseLocal) { Text("Use the on-device model").fontWeight(.medium) }
                if model.rewriteUseLocal {
                    DownloadRow(status: state.localModelStatus,
                                sizeNote: "Qwen3-4B-Instruct · about 2.5 GB · no key, runs offline on your Mac",
                                download: { state.localModelStore.download() },
                                cancel:   { state.localModelStore.cancel() })
                }

                if !model.rewriteUseClaude && !model.rewriteUseLocal {
                    Text("Pick at least one so rewriting has something to run.")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("Rewriting stays off for now. It is a core part of Dictidy, and you can turn it on anytime in Settings.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PermissionsStep: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var model: OnboardingModel

    private var needAccessibility: Bool { model.dictationEnabled || model.rewriteEnabled }
    private var needMic: Bool { model.dictationEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepTitle("Permissions", "Grant the access the features you turned on need. Dictidy uses these only to work in your other apps. Nothing is recorded.")

            if needAccessibility {
                VStack(alignment: .leading, spacing: 8) {
                    if model.accessibilityGranted {
                        StatusRow(title: "Accessibility", state: .ready, badgeLabel: "Granted",
                                  caption: "Lets Dictidy read your selection and paste results into any app.")
                    } else {
                        StatusRow(title: "Accessibility", state: .actionNeeded, badgeLabel: "Waiting…",
                                  caption: "Enable Dictidy in the list. If macOS asks you to relaunch, the wizard resumes right here.") {
                            Button("Open Settings…") { AccessibilityPermissions.openSettings() }
                        }
                    }
                }
            }

            if needMic {
                Divider()
                if model.micGranted {
                    StatusRow(title: "Microphone", state: .ready, badgeLabel: "Granted",
                              caption: "Used only while you dictate. Audio is transcribed on your Mac.")
                } else {
                    StatusRow(title: "Microphone", state: .actionNeeded, badgeLabel: "Not granted",
                              caption: "Needed for dictation. Audio never leaves your Mac.") {
                        Button("Grant") { MicrophonePermissions.request { _ in } }
                    }
                }
            }

            if !needAccessibility && !needMic {
                Text("You turned both features off, so there is nothing to grant right now. You can enable them and grant access anytime in Settings.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct DoneStep: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 16) {
            Text("You're all set").font(.title).bold()
            Text("Everything you turned on is verified and ready.").font(.callout).foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    summary("Dictation", model.dictationEnabled ? "On · \(dictationShortcut)" : "Off",
                            on: model.dictationEnabled)
                    summary("Rewriting", model.rewriteEnabled ? rewriteDetail : "Off",
                            on: model.rewriteEnabled)
                    if model.dictationEnabled || model.rewriteEnabled {
                        summary("Accessibility", model.accessibilityGranted ? "Granted" : "Grant in Settings",
                                on: model.accessibilityGranted)
                    }
                }.padding(6)
            }
            Label("Select text anywhere and press ⇧⌘R to rewrite. Find Dictidy in your menu bar, up top.",
                  systemImage: "arrow.up.right")
                .font(.caption).foregroundStyle(.secondary)
                .padding(10).background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxWidth: .infinity, minHeight: 430)
    }

    private var dictationShortcut: String {
        state.shortcutDescription(forName: ShortcutsRegistry.dictateAndCleanName)
            ?? state.shortcutDescription(forName: ShortcutsRegistry.dictateName)
            ?? OnboardingModel.defaultDictateCleanShortcut
    }

    private var rewriteDetail: String {
        switch (model.rewriteUseClaude, model.rewriteUseLocal) {
        case (true, true):   return "Claude and on-device"
        case (true, false):  return "Claude"
        case (false, true):  return "On-device"
        case (false, false): return "On"
        }
    }

    private func summary(_ title: String, _ detail: String, on: Bool) -> some View {
        HStack {
            StatusBadge(on ? .ready : .actionNeeded, label: title)
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Small shared pieces

private struct StepTitle: View {
    let title: String; let subtitle: String?
    init(_ t: String, _ s: String?) { title = t; subtitle = s }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2).bold()
            if let subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ProgressDots: View {
    @ObservedObject var model: OnboardingModel
    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<model.steps.count, id: \.self) { i in
                Capsule().fill(i == model.index ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(width: i == model.index ? 22 : 6, height: 6)
            }
        }
    }
}

/// Renders any of the app's `ModelStatus` download states with a live progress bar.
private struct DownloadRow: View {
    let status: ModelStatus
    let sizeNote: String
    let download: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch status {
            case .ready:
                StatusBadge(.ready, label: "Downloaded")
            case .missing:
                Button("Download") { download() }.buttonStyle(.borderedProminent)
            case .downloading(let p):
                HStack(spacing: 10) {
                    ProgressView(value: p).frame(maxWidth: 220)
                    Text("\(Int(p * 100))%").font(.caption).monospacedDigit()
                    Button("Cancel") { cancel() }
                }
            case .failed(let msg):
                Text(msg).font(.callout).foregroundStyle(.orange)
                Button("Retry download") { download() }
            }
            Text(sizeNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
