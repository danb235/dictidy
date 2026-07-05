import SwiftUI
import KeyboardShortcuts

// First-run onboarding wizard for Dictidy.
//
// One guided window that takes a brand-new user from install to fully working. The user chooses
// what to set up (Claude / on-device / both, and whether to enable dictation); every permission
// and download is requested INLINE and VERIFIED LIVE — Continue stays disabled until the step's
// check actually passes, so the user is genuinely set up when the wizard closes.
//
// Reuses the app's existing services: AccessibilityPermissions, MicrophonePermissions,
// KeychainService, AppState.saveAPIKey / refreshModels / modelStore / localModelStore,
// KeyboardShortcuts.Recorder, and the shared StatusBadge.
//
// ── Integration ──────────────────────────────────────────────────────────────────────────────
// In DictidyApp.swift add a window scene and open it on first launch:
//
//     @AppStorage("hasCompletedOnboarding") private var onboarded = false
//     ...
//     Window("Welcome to Dictidy", id: "onboarding") {
//         OnboardingView().environmentObject(state)
//             .frame(width: 480, height: 560)
//     }
//     .windowResizability(.contentSize)
//
// and in AppDelegate.applicationDidFinishLaunching (or via openWindow on appear):
//     if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") { open "onboarding" }
// Also add a menu item "Run setup again…" that reopens it.

// MARK: - Choices & steps

enum RewriteChoice: String, CaseIterable { case claude, onDevice, both
    var title: String {
        switch self { case .claude: "Claude"; case .onDevice: "On-device"; case .both: "Both + fallback" }
    }
    var usesClaude: Bool   { self == .claude || self == .both }
    var usesOnDevice: Bool { self == .onDevice || self == .both }
}

enum OnboardingStep: Hashable { case welcome, choose, accessibility, rewrite, dictation, done }

// MARK: - Model

@MainActor
final class OnboardingModel: ObservableObject {
    private let defaults = UserDefaults.standard
    private enum Keys {
        static let index = "onboarding.index"
        static let choice = "onboarding.rewriteChoice"
        static let dictation = "onboarding.dictationEnabled"
    }

    @Published var index = 0 { didSet { defaults.set(index, forKey: Keys.index) } }
    @Published var rewriteChoice: RewriteChoice = .both { didSet { defaults.set(rewriteChoice.rawValue, forKey: Keys.choice) } }
    @Published var dictationEnabled = true { didSet { defaults.set(dictationEnabled, forKey: Keys.dictation) } }

    // Live-verified state (polled).
    @Published var accessibilityGranted = AccessibilityPermissions.isTrusted
    @Published var micGranted = MicrophonePermissions.isGranted

    private var timer: Timer?

    init() {
        // Resume where a previous session left off — e.g. after granting Accessibility, which can
        // require an app relaunch; the wizard reopens on the same step with its check now passing.
        index = defaults.integer(forKey: Keys.index)
        if let raw = defaults.string(forKey: Keys.choice), let c = RewriteChoice(rawValue: raw) { rewriteChoice = c }
        if defaults.object(forKey: Keys.dictation) != nil { dictationEnabled = defaults.bool(forKey: Keys.dictation) }
    }

    /// The visible sequence, derived from the user's choices.
    var steps: [OnboardingStep] {
        var s: [OnboardingStep] = [.welcome, .choose, .accessibility, .rewrite]
        if dictationEnabled { s.append(.dictation) }
        s.append(.done)
        return s
    }
    var step: OnboardingStep { steps[min(index, steps.count - 1)] }
    var isFirst: Bool { index == 0 }
    var isLast: Bool { step == .done }

    func next() { if index < steps.count - 1 { index += 1 } }
    func back() { if index > 0 { index -= 1 } }

    /// Poll the permissions that can change outside the app (System Settings), so the UI verifies
    /// itself without the user having to come back and click anything.
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
        // Persist the chosen provider strategy.
        switch rewriteChoice {
        case .claude:   state.rewriteProvider = .anthropic; state.fallbackEnabled = false
        case .onDevice: state.rewriteProvider = .local;     state.fallbackEnabled = false
        case .both:     state.rewriteProvider = .anthropic; state.fallbackEnabled = true
        }
        defaults.set(true, forKey: "hasCompletedOnboarding")
        [Keys.index, Keys.choice, Keys.dictation].forEach { defaults.removeObject(forKey: $0) }
        stopPolling()
    }
}

// MARK: - Root view

struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = OnboardingModel()

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 34).padding(.top, 30)

            if model.step != .welcome && model.step != .done { ProgressDots(model: model).padding(.top, 8) }

            footer.padding(24)
        }
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome:       WelcomeStep()
        case .choose:        ChooseStep(model: model)
        case .accessibility: AccessibilityStep(model: model)
        case .rewrite:       RewriteStep(model: model)
        case .dictation:     DictationStep(model: model)
        case .done:          DoneStep(model: model)
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
        case .welcome, .choose, .done: return true
        case .accessibility:           return model.accessibilityGranted
        case .rewrite:
            let claudeOK = !model.rewriteChoice.usesClaude || state.anthropicReady
            let localOK  = !model.rewriteChoice.usesOnDevice || state.localModelReady
            return claudeOK && localOK
        case .dictation:
            let modelReady: Bool = { if case .ready = state.modelStatus { return true }; return false }()
            return model.micGranted && modelReady
        }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            WaveformIcon(mode: .idle)
                .frame(width: 44, height: 44)
                .padding(20)
                .background(LinearGradient(colors: [.blue, .indigo], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 20))
                .foregroundStyle(.white)
            Text("Welcome to Dictidy").font(.title).bold()
            Text("Rewrite and dictate text anywhere on your Mac with a keystroke. Let's get you set up — about a minute.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 320)
            Spacer()
        }
    }
}

private struct ChooseStep: View {
    @ObservedObject var model: OnboardingModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepTitle("What do you want to set up?", "You can change any of this later in Settings.")
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Rewriting").fontWeight(.semibold)
                    Picker("", selection: $model.rewriteChoice) {
                        ForEach(RewriteChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                    Text("Claude is highest quality; on-device works offline with no key. “Both” uses Claude and falls back automatically.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(6)
            }
            GroupBox {
                Toggle(isOn: $model.dictationEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Voice dictation").fontWeight(.semibold)
                        Text("Optional · on-device speech-to-text").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(6)
            }
            Spacer()
        }
    }
}

private struct AccessibilityStep: View {
    @ObservedObject var model: OnboardingModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepTitle("Let Dictidy work in any app",
                      "macOS Accessibility access lets Dictidy copy your selected text and paste the result back. It’s used only for that — nothing is recorded.")
            Button("Open Accessibility Settings…") { AccessibilityPermissions.openSettings() }
                .controlSize(.large)
            if model.accessibilityGranted {
                StatusRow(title: "Accessibility", state: .ready, badgeLabel: "Granted",
                          caption: "Detected automatically — you can continue.")
            } else {
                StatusRow(title: "Accessibility", state: .actionNeeded, badgeLabel: "Waiting…",
                          caption: "Enable Dictidy in the list. If macOS asks you to relaunch, the wizard resumes right here.")
            }
            Spacer()
        }
    }
}

private struct RewriteStep: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var model: OnboardingModel
    @State private var key = KeychainService.load() ?? ""
    @State private var refreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepTitle("Set up rewriting", nil)

            if model.rewriteChoice.usesClaude {
                Text("Paste your Anthropic API key — stored in the Keychain, only ever sent to api.anthropic.com.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                    StatusBadge(.ready, label: "Valid key — \(state.models.count) models loaded")
                    Picker("Model", selection: $state.selectedModelID) {
                        ForEach(state.models.sortedByDisplayName()) { Text($0.displayName).tag($0.id) }
                    }.pickerStyle(.menu)
                } else {
                    Link("Get a key ↗", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                        .font(.callout)
                }
            }

            if model.rewriteChoice.usesOnDevice {
                Divider()
                Text("On-device model").fontWeight(.semibold)
                DownloadRow(status: state.localModelStatus,
                            sizeNote: "Qwen3-4B-Instruct · ~2.5 GB · runs entirely on your Mac",
                            download: { state.localModelStore.download() },
                            cancel:   { state.localModelStore.cancel() })
            }
            Spacer()
        }
    }
}

private struct DictationStep: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var model: OnboardingModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepTitle("Set up dictation", "Everything runs on-device — your audio never leaves your Mac.")

            if model.micGranted {
                StatusRow(title: "Microphone", state: .ready, badgeLabel: "Granted")
            } else {
                StatusRow(title: "Microphone", state: .actionNeeded, badgeLabel: "Not granted") {
                    Button("Grant") { MicrophonePermissions.request { _ in } }
                }
            }

            Text("Speech model").fontWeight(.semibold)
            DownloadRow(status: state.modelStatus,
                        sizeNote: "Whisper large-v3-turbo · ~1.6 GB",
                        download: { state.modelStore.download() },
                        cancel:   { state.modelStore.cancel() })

            Divider()
            KeyboardShortcuts.Recorder("Dictate", name: .init(ShortcutsRegistry.dictateName))
            KeyboardShortcuts.Recorder("Dictate + Clean", name: .init(ShortcutsRegistry.dictateAndCleanName))
            Spacer()
        }
    }
}

private struct DoneStep: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var model: OnboardingModel
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("You’re all set").font(.title).bold()
            Text("Everything below is verified and working.").font(.callout).foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    summary("Accessibility", "Granted")
                    if model.rewriteChoice.usesClaude || model.rewriteChoice.usesOnDevice {
                        summary("Rewriting", model.rewriteChoice.title)
                    }
                    if model.dictationEnabled { summary("Dictation", "⌥Space / ⌃Space") }
                }.padding(6)
            }
            Label("Select text anywhere and press ⇧⌘R. Find Dictidy in your menu bar, up top.",
                  systemImage: "arrow.up.right")
                .font(.caption).foregroundStyle(.secondary)
                .padding(10).background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            Spacer()
        }
    }
    private func summary(_ title: String, _ detail: String) -> some View {
        HStack { StatusBadge(.ready, label: title); Spacer(); Text(detail).font(.caption).foregroundStyle(.secondary) }
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

/// Renders any of the app's `ModelStatus`-style download states with a live progress bar.
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
