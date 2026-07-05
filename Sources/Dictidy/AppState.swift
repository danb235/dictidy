import AppKit
import AudioToolbox
import SwiftUI
import KeyboardShortcuts
import DictidyKit

/// Which Settings tab to show — lets the menu deep-link to the relevant setup step.
enum SettingsTab: Hashable {
    case rewrite, instructions, dictation, general
}

/// Which dictation action a recording performs when it stops.
enum DictationMode { case raw, clean }

/// Central app state: instructions, live model list, selection, settings. Persists to
/// UserDefaults (instructions + cached models) and the Keychain (API key), and wires the
/// global shortcuts to the rewrite flow.
@MainActor
final class AppState: ObservableObject {
    @Published var instructions: [Instruction] = []
    @Published var models: [AnthropicModel] = []
    @Published var modelsLastFetched: Date?
    @Published var hasAPIKey: Bool = false { didSet { updateSetupPulse() } }
    @Published var launchAtLogin: Bool = false
    @Published var isWorking: Bool = false {
        didSet {
            guard isWorking != oldValue else { return }
            if isWorking { cancelErrorFlash(); startSpinner() } else { stopSpinner() }
            updateSetupPulse()
        }
    }
    @Published var statusMessage: String?
    /// Incrementing frame counter that drives the menu-bar spinner animation while working.
    @Published var spinnerFrame: Int = 0
    /// Frame counter driving the "setup needed" attention pulse (mirrors spinnerFrame).
    @Published var setupFrame: Int = 0
    /// When true, the menu-bar icon briefly shows the `nosign` glyph to signal a
    /// no-selection failure — a lightweight, non-modal alternative to the alert.
    @Published var showErrorFlash: Bool = false
    /// Live Accessibility-permission state. macOS posts no reliable change event, so we poll —
    /// but only while it's missing (see `startPermissionMonitorIfNeeded`), never once granted.
    @Published var accessibilityTrusted: Bool = AccessibilityPermissions.isTrusted { didSet { updateSetupPulse() } }
    /// Deep-link target when the menu opens the Settings window for a specific setup step.
    @Published var settingsTab: SettingsTab = .rewrite

    @Published var selectedModelID: String = "" {
        didSet { defaults.set(selectedModelID, forKey: Keys.selectedModel); updateSetupPulse() }
    }
    /// The primary backend for rewrites. Anthropic by default; `local` uses the on-device model.
    @Published var rewriteProvider: RewriteProvider = .anthropic {
        didSet { defaults.set(rewriteProvider.rawValue, forKey: Keys.rewriteProvider); updateSetupPulse() }
    }
    /// When true, a rewrite falls back to the *other* provider if the primary is unavailable
    /// (offline, no key, rate-limited, server error, or model not loaded). Opt-in; default off.
    @Published var fallbackEnabled: Bool = false {
        didSet { defaults.set(fallbackEnabled, forKey: Keys.fallbackEnabled); updateSetupPulse() }
    }
    /// Mirror of the local rewrite model download/readiness status, for the Rewrite settings UI.
    @Published var localModelStatus: ModelStatus = .missing { didSet { updateSetupPulse() } }
    @Published var restoreClipboard: Bool = true {
        didSet { defaults.set(restoreClipboard, forKey: Keys.restoreClipboard) }
    }
    /// Recorded before/after text of past rewrites (newest first), so the user can recover text
    /// they later lose. Persisted to a JSON file, not UserDefaults (see HistoryStore).
    @Published var history: [HistoryEntry] = []
    @Published var keepHistory: Bool = true {
        didSet { defaults.set(keepHistory, forKey: Keys.keepHistory) }
    }
    /// Dictation recording state; drives the menu-bar "listening" animation.
    @Published var isRecording: Bool = false {
        didSet {
            guard isRecording != oldValue else { return }
            if isRecording { cancelErrorFlash(); startRecordingAnimation() } else { stopRecordingAnimation() }
            updateSetupPulse()
        }
    }
    /// Frame counter driving the listening pulse (like `spinnerFrame` drives the working spinner).
    @Published var recordingFrame: Int = 0
    /// Mirror of the Whisper model download/readiness status, for the Dictation settings UI.
    @Published var modelStatus: ModelStatus = .missing { didSet { updateSetupPulse() } }
    @Published var playDictationTones: Bool = true {
        didSet { defaults.set(playDictationTones, forKey: Keys.playDictationTones) }
    }
    /// Instruction used by "Dictate + Clean" (default: the Auto Clean instruction).
    @Published var dictationCleanupInstructionID: UUID? {
        didSet { defaults.set(dictationCleanupInstructionID?.uuidString, forKey: Keys.dictationCleanupInstruction) }
    }

    let modelStore = WhisperModelStore()
    let localModelStore = LocalLLMModelStore()
    private let registry = ShortcutsRegistry()
    private let defaults = UserDefaults.standard
    /// In-memory copy of the API key, read from the Keychain lazily on first use and cached for
    /// the app's lifetime. Reading the Keychain triggers a macOS authorization prompt, so we do
    /// it at most once per launch instead of on every rewrite. Kept in sync on save/remove.
    private var cachedAPIKey: String?
    private var spinnerTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    /// Rolling streak of consecutive no-selection failures; drives escalation to the modal.
    private var noSelectionFailureCount = 0
    private var lastNoSelectionFailure: Date?
    private let failureWindow: TimeInterval = 8            // rolling gap that keeps a streak alive
    private let failureEscalationThreshold = 3             // 3rd rapid failure → show the window
    private let historyLimit = 100                         // keep only the newest N rewrites
    private var whisperEngine: WhisperEngine?
    private var localEngine: LocalLLMEngine?
    private var dictationMode: DictationMode?
    private var recordingTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    /// Releases resident models after a spell of inactivity so a one-off rewrite/dictation doesn't
    /// pin GBs of memory for the rest of the session. Re-armed on each use.
    private var idleUnloadTask: Task<Void, Never>?
    private let idleUnloadDelay: UInt64 = 240_000_000_000   // 4 minutes
    /// System-sound IDs for the dictation start/stop tones, loaded once. Played via AudioServices
    /// (not NSSound) so playback doesn't depend on a retained object and isn't clipped by the audio
    /// engine grabbing the mic.
    private lazy var startSoundID: SystemSoundID = Self.loadSystemSound("Tink")
    private lazy var stopSoundID: SystemSoundID = Self.loadSystemSound("Pop")

    private enum Keys {
        static let seeded = "didSeedDefaults"
        static let instructions = "instructions"
        static let selectedModel = "selectedModelID"
        static let rewriteProvider = "rewriteProvider"
        static let fallbackEnabled = "fallbackEnabled"
        static let restoreClipboard = "restoreClipboard"
        static let models = "cachedModels"
        static let modelsFetched = "modelsLastFetched"
        static let keepHistory = "keepHistory"
        static let playDictationTones = "playDictationTones"
        static let dictationCleanupInstruction = "dictationCleanupInstruction"
    }

    init() {
        loadPersisted()
        hasAPIKey = KeychainService.exists() // existence check — doesn't read the secret, so no prompt at launch
        launchAtLogin = LaunchAtLogin.isEnabled

        registry.onTrigger = { [weak self] id in
            guard let self, let instruction = self.instructions.first(where: { $0.id == id }) else { return }
            Task { await self.runRewrite(instruction: instruction) }
        }
        registry.sync(instructions)
        registry.onDictate = { [weak self] in self?.toggleDictation(mode: .raw) }
        registry.onDictateAndClean = { [weak self] in self?.toggleDictation(mode: .clean) }
        registry.registerStandalone()
        startPermissionMonitorIfNeeded()

        modelStore.onStatusChange = { [weak self] status in self?.modelStatus = status }
        modelStore.resolve()

        localModelStore.onStatusChange = { [weak self] status in self?.localModelStatus = status }
        localModelStore.resolve()

        // Refresh the live model list at launch only when we have nothing cached to show —
        // otherwise we'd read the Keychain (and trigger its auth prompt) on every launch. With a
        // cached list, models refresh on demand (Settings → Refresh) or when the key is saved.
        if hasAPIKey && models.isEmpty {
            Task { await refreshModels() }
        }

        updateSetupPulse()   // start the attention pulse if the app launches needing setup
    }

    // MARK: - Setup status

    /// True when the app can't actually perform a rewrite yet — drives the menu-bar warning state
    /// and the in-menu setup checklist. Order-aware: if a configured fallback covers an unconfigured
    /// primary, the app *can* rewrite, so no warning. Accessibility is needed regardless.
    var needsSetup: Bool {
        !accessibilityTrusted || effectiveProviderOrder().isEmpty
    }

    /// Whether the Anthropic path is usable (uses the cheap `hasAPIKey` existence flag — never reads
    /// the Keychain secret, so this stays prompt-free even when evaluated on every menu open).
    var anthropicReady: Bool { hasAPIKey && !selectedModelID.isEmpty }

    /// Whether the on-device rewrite model is downloaded and ready.
    var localModelReady: Bool {
        if case .ready = localModelStatus { return true }
        return false
    }

    /// Providers to try for one rewrite, in order (primary, then fallback if enabled + ready).
    func effectiveProviderOrder() -> [RewriteProvider] {
        rewriteProviderOrder(primary: rewriteProvider, fallbackEnabled: fallbackEnabled,
                             anthropicReady: anthropicReady, localReady: localModelReady)
    }

    /// Short label for the provider a rewrite will use right now (respects primary + fallback),
    /// for the menu "Ready · …" footer. Empty when nothing is set up.
    var activeProviderLabel: String {
        switch effectiveProviderOrder().first {
        case .anthropic: return models.first(where: { $0.id == selectedModelID })?.displayName ?? "Claude"
        case .local:     return "on-device model"
        case nil:        return ""
        }
    }

    /// The user has engaged with dictation: a dictation shortcut is bound, OR the model download
    /// has started/finished. A user who never touches dictation stays false (so no nagging).
    var dictationEngaged: Bool {
        let hasShortcut = shortcutDescription(forName: ShortcutsRegistry.dictateName) != nil
            || shortcutDescription(forName: ShortcutsRegistry.dictateAndCleanName) != nil
        switch modelStatus {
        case .downloading, .ready: return true
        case .missing, .failed:    return hasShortcut
        }
    }

    /// Dictation can't run yet — but only worth flagging once the user has engaged with it.
    var dictationNeedsSetup: Bool {
        guard dictationEngaged else { return false }
        let modelReady = { if case .ready = modelStatus { return true }; return false }()
        return !modelReady || !MicrophonePermissions.isGranted
    }

    /// Human-readable shortcut for an instruction (e.g. "⇧⌘R"), or nil if none is bound.
    func shortcutDescription(for instruction: Instruction) -> String? {
        KeyboardShortcuts.getShortcut(for: KeyboardShortcuts.Name(instruction.shortcutKey))?.description
    }

    /// Human-readable shortcut for a standalone shortcut name (dictate / dictate-and-clean).
    func shortcutDescription(forName name: String) -> String? {
        KeyboardShortcuts.getShortcut(for: KeyboardShortcuts.Name(name))?.description
    }

    /// Polls Accessibility trust ONLY while it's missing, so the warning clears live when the
    /// user grants it. Stops as soon as it's granted; nothing polls in the steady, set-up state.
    func startPermissionMonitorIfNeeded() {
        guard !accessibilityTrusted, permissionTask == nil else { return }
        permissionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s
                guard let self else { break }
                let trusted = AccessibilityPermissions.isTrusted
                if trusted != self.accessibilityTrusted {
                    self.accessibilityTrusted = trusted
                }
                if trusted { break } // granted — stop polling
            }
            self?.permissionTask = nil
        }
    }

    // MARK: - Rewrite flow

    func runRewrite(instruction: Instruction) async {
        guard !isWorking, !isRecording else { return }

        let order = effectiveProviderOrder()
        guard !order.isEmpty else {
            settingsTab = .rewrite
            notify("Set up a rewrite provider first.\n\nOpen Settings → Rewrite and either add your Anthropic API key + pick a model, or download the local (on-device) model.")
            return
        }
        guard AccessibilityPermissions.isTrusted else {
            accessibilityTrusted = false
            startPermissionMonitorIfNeeded() // resume live polling while the user grants it
            notify("Dictidy needs Accessibility access to copy your selection and paste the result.\n\nEnable Dictidy in System Settings → Privacy & Security → Accessibility, then quit and relaunch Dictidy.")
            AccessibilityPermissions.prompt()
            return
        }

        isWorking = true
        statusMessage = "Rewriting…"

        guard let selection = await RewriteService.shared.captureSelection() else {
            isWorking = false
            statusMessage = nil
            handleNoSelection()
            return
        }

        await performRewrite(order: order, text: selection, instruction: instruction, before: selection, kind: .rewrite)
        noSelectionFailureCount = 0
        lastNoSelectionFailure = nil
        isWorking = false
        statusMessage = nil
    }

    /// Runs `text` through the providers in `order` (primary, then fallback), records history
    /// (attributed to whichever provider succeeded) and pastes the result. On a provider failure it
    /// advances to the next only if the error means the provider is *unavailable* (see
    /// `shouldFallback`); a genuine request/content error surfaces instead. Notifies once, only if
    /// the whole order fails. Caller owns isWorking. Shared by the selection rewrite and Dictate + Clean.
    private func performRewrite(order: [RewriteProvider], text: String, instruction: Instruction,
                                before: String, kind: HistoryKind) async {
        var lastError: Error?
        for (index, provider) in order.enumerated() {
            if index > 0 { statusMessage = "Falling back to \(provider.displayName)…" }
            do {
                let (result, modelName) = try await generate(with: provider, text: text,
                                                             systemPrompt: instruction.systemPrompt)
                recordHistory(before: before, after: result, instructionName: instruction.name,
                              model: modelName, kind: kind)
                await RewriteService.shared.paste(result, restoreClipboard: restoreClipboard)
                scheduleIdleUnload()
                return
            } catch {
                lastError = error
                if !shouldFallback(after: error) { break }   // request/content error → surface it
            }
        }
        notify(lastError?.localizedDescription ?? "The rewrite failed.")
    }

    /// Generates a rewrite with a single provider, returning the text and the model name to record.
    private func generate(with provider: RewriteProvider, text: String, systemPrompt: String) async throws -> (String, String) {
        // Frame the text as inert material to rewrite (not a request to answer), so a dictation phrased
        // at the assistant gets cleaned instead of obeyed. Applied here so every provider sees it.
        let userText = rewriteInputMessage(text)
        switch provider {
        case .anthropic:
            guard let key = apiKey(), !key.isEmpty else { throw AnthropicError.missingAPIKey }
            // Shorten the timeout when a local fallback can pick up, so a hung request fails over fast.
            let timeout: TimeInterval = (fallbackEnabled && localModelReady) ? 25 : 60
            let result = try await AnthropicClient(apiKey: key).rewrite(
                text: userText, systemPrompt: systemPrompt, model: selectedModelID, timeout: timeout)
            let name = models.first(where: { $0.id == selectedModelID })?.displayName ?? selectedModelID
            return (result, name)
        case .local:
            let engine = try await resolveLocalEngine()
            return (try await engine.rewrite(text: userText, systemPrompt: systemPrompt),
                    LocalLLMModelStore.modelDisplayName)
        }
    }

    /// Whether a provider error should advance to the next provider. Anthropic: only availability
    /// failures (see `AnthropicError.isAvailabilityFailure`). Local-engine failures always fall back
    /// (Claude is more capable). Anything else (unexpected) falls back too.
    private func shouldFallback(after error: Error) -> Bool {
        if let e = error as? AnthropicError { return e.isAvailabilityFailure }
        return true
    }

    /// Re-run `text` (e.g. from History) through the active provider + instruction, record the
    /// result (so it appears at the top of History), and copy it to the clipboard. Unlike
    /// `performRewrite` it does not paste — it's invoked from the History window, where there's no
    /// text cursor to paste into.
    func rewriteAgain(_ text: String, instruction: Instruction) async {
        guard !isWorking, !isRecording, !text.isEmpty else { return }
        let order = effectiveProviderOrder()
        guard !order.isEmpty else {
            settingsTab = .rewrite
            notify("Set up a rewrite provider first — Settings → Rewrite.")
            return
        }
        isWorking = true
        statusMessage = "Rewriting…"
        var lastError: Error?
        for (index, provider) in order.enumerated() {
            if index > 0 { statusMessage = "Falling back to \(provider.displayName)…" }
            do {
                let (result, modelName) = try await generate(with: provider, text: text,
                                                             systemPrompt: instruction.systemPrompt)
                recordHistory(before: text, after: result, instructionName: instruction.name,
                              model: modelName, kind: .rewrite)
                copyToClipboard(result)
                scheduleIdleUnload()
                isWorking = false
                statusMessage = nil
                return
            } catch {
                lastError = error
                if !shouldFallback(after: error) { break }
            }
        }
        isWorking = false
        statusMessage = nil
        notify(lastError?.localizedDescription ?? "The rewrite failed.")
    }

    /// Builds (once) and returns the local LLM engine from the downloaded model. The ~2.5 GB load
    /// runs off the main actor; the engine is cached until idle-unload releases it.
    private func resolveLocalEngine() async throws -> LocalLLMEngine {
        if let engine = localEngine { return engine }
        guard case .ready(let url) = localModelStatus else {
            throw LocalLLMEngine.EngineError.modelLoadFailed("model not installed")
        }
        let engine = try await Task.detached(priority: .userInitiated) {
            try LocalLLMEngine(modelURL: url)
        }.value
        localEngine = engine
        return engine
    }

    /// Releases resident models (local LLM + Whisper) after `idleUnloadDelay` of no activity, so a
    /// single rewrite/dictation doesn't keep GBs mapped for the rest of the session. Setting the
    /// actors to nil runs their deinit (llama_free / whisper_free). Re-armed on each use.
    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.idleUnloadDelay)
            guard !Task.isCancelled, !self.isWorking, !self.isRecording else { return }
            self.localEngine = nil
            self.whisperEngine = nil
            self.idleUnloadTask = nil
        }
    }

    // MARK: - Dictation

    /// Instruction that "Dictate + Clean" runs the transcript through (default: Auto Clean).
    var dictationCleanupInstruction: Instruction? {
        if let id = dictationCleanupInstructionID, let match = instructions.first(where: { $0.id == id }) {
            return match
        }
        return instructions.first(where: { $0.name == "Auto Clean" }) ?? instructions.first
    }

    /// Tap-to-toggle: start recording if idle, else stop and process using the mode that started it.
    func toggleDictation(mode: DictationMode) {
        if isRecording { stopAndProcess() } else { startDictation(mode: mode) }
    }

    func startDictation(mode: DictationMode) {
        guard !isWorking, !isRecording else { return }
        guard AccessibilityPermissions.isTrusted else {
            accessibilityTrusted = false
            startPermissionMonitorIfNeeded()
            notify("Dictidy needs Accessibility access to paste dictated text.\n\nEnable Dictidy in System Settings → Privacy & Security → Accessibility, then quit and relaunch Dictidy.")
            AccessibilityPermissions.prompt()
            return
        }
        guard case .ready(let modelURL) = modelStatus else {
            settingsTab = .dictation
            notify("The dictation speech model isn't installed yet.\n\nOpen Settings → Dictation and download it (about 1.6 GB), then try again.")
            return
        }
        switch MicrophonePermissions.status {
        case .authorized:
            beginRecording(mode: mode, modelURL: modelURL)
        case .notDetermined:
            MicrophonePermissions.request { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.beginRecording(mode: mode, modelURL: modelURL)
                } else {
                    self.notify("Microphone access is needed to dictate. Enable it in System Settings → Privacy & Security → Microphone.")
                }
            }
        default:
            settingsTab = .dictation
            notify("Microphone access is off.\n\nEnable Dictidy in System Settings → Privacy & Security → Microphone, then try again.")
            MicrophonePermissions.openSettings()
        }
    }

    private func beginRecording(mode: DictationMode, modelURL: URL) {
        playTone(start: true)   // before the engine grabs the mic, so the tone isn't clipped
        do {
            try DictationService.shared.start()
        } catch {
            notify("Couldn't start recording: \(error.localizedDescription)")
            return
        }
        dictationMode = mode
        isRecording = true
        preloadEngine(modelURL: modelURL)   // load the model while the user talks
        startWatchdog()
    }

    func stopAndProcess() {
        guard isRecording else { return }
        isRecording = false
        stopWatchdog()
        let mode = dictationMode ?? .clean
        let samples = DictationService.shared.stopAndCollect()
        playTone(start: false)   // after the tap is removed, so the tone isn't captured into the audio
        guard !samples.isEmpty else { startErrorFlash(); return }   // no audio captured

        isWorking = true
        statusMessage = "Transcribing…"
        Task {
            do {
                let engine = try await resolveEngine()
                let transcript = try await engine.transcribe(samples)
                switch mode {
                case .raw:
                    recordRawDictation(transcript: transcript)
                    await RewriteService.shared.paste(transcript, restoreClipboard: restoreClipboard)
                    scheduleIdleUnload()
                case .clean:
                    let order = effectiveProviderOrder()
                    if let instruction = dictationCleanupInstruction, !order.isEmpty {
                        statusMessage = "Cleaning…"
                        await performRewrite(order: order, text: transcript, instruction: instruction,
                                             before: transcript, kind: .dictationClean)
                    } else {
                        // No cleanup instruction or no rewrite provider set up — paste the raw transcript.
                        recordRawDictation(transcript: transcript)
                        await RewriteService.shared.paste(transcript, restoreClipboard: restoreClipboard)
                        scheduleIdleUnload()
                    }
                }
                isWorking = false
                statusMessage = nil
            } catch WhisperEngine.EngineError.emptyTranscription {
                isWorking = false
                statusMessage = nil
                startErrorFlash()   // silence / no speech — quiet feedback, no modal
            } catch {
                isWorking = false
                statusMessage = nil
                notify(error.localizedDescription)
            }
        }
    }

    /// Builds (once) and returns the Whisper engine from the resolved model. The ~1.6 GB load
    /// runs off the main actor; the engine is cached for the process lifetime.
    private func resolveEngine() async throws -> WhisperEngine {
        if let engine = whisperEngine { return engine }
        guard case .ready(let url) = modelStatus else {
            throw WhisperEngine.EngineError.modelLoadFailed("model not installed")
        }
        let engine = try await Task.detached(priority: .userInitiated) {
            try WhisperEngine(modelURL: url)
        }.value
        whisperEngine = engine
        return engine
    }

    /// Preload the engine at record start so the model load overlaps with the user speaking.
    private func preloadEngine(modelURL: URL) {
        guard whisperEngine == nil else { return }
        Task { [weak self] in _ = try? await self?.resolveEngine() }
    }

    private func playTone(start: Bool) {
        guard playDictationTones else { return }
        AudioServicesPlaySystemSound(start ? startSoundID : stopSoundID)
    }

    private static func loadSystemSound(_ name: String) -> SystemSoundID {
        var id: SystemSoundID = 0
        AudioServicesCreateSystemSoundID(URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff") as CFURL, &id)
        return id
    }

    /// Advances `recordingFrame` on a timer so the menu-bar mic visibly pulses while listening.
    private func startRecordingAnimation() {
        recordingTask?.cancel()
        recordingFrame = 0
        recordingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 90_000_000) // ~11 fps
                guard let self, !Task.isCancelled else { break }
                self.recordingFrame &+= 1
            }
        }
    }

    private func stopRecordingAnimation() {
        recordingTask?.cancel()
        recordingTask = nil
    }

    /// Auto-stops a runaway recording after 5 minutes (bounds memory; 5 min ≈ 18 MB of samples).
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000_000) // 5 min
            guard let self, !Task.isCancelled, self.isRecording else { return }
            self.stopAndProcess()
        }
    }

    private func stopWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    // MARK: - API key

    /// The API key, read from the Keychain once (on first use) and cached in memory thereafter,
    /// so we never re-prompt for Keychain access on subsequent rewrites. Returns nil if unset.
    private func apiKey() -> String? {
        if cachedAPIKey == nil {
            cachedAPIKey = KeychainService.load()
        }
        return cachedAPIKey
    }

    func saveAPIKey(_ key: String) {
        KeychainService.save(key)
        cachedAPIKey = key
        hasAPIKey = true
        Task { await refreshModels() }
    }

    func removeAPIKey() {
        KeychainService.delete()
        cachedAPIKey = nil
        hasAPIKey = false
        models = []
        persistModels()
    }

    // MARK: - Models

    func refreshModels() async {
        guard let key = apiKey(), !key.isEmpty else {
            notify("Add your API key first.")
            return
        }
        do {
            let list = try await AnthropicClient(apiKey: key).listModels()
            models = list
            modelsLastFetched = Date()
            persistModels()
            if selectedModelID.isEmpty || !list.contains(where: { $0.id == selectedModelID }) {
                selectedModelID = AnthropicModel.preferredDefault(from: list)
            }
        } catch {
            notify(error.localizedDescription)
        }
    }

    // MARK: - Instructions CRUD

    func addInstruction(_ instruction: Instruction) {
        instructions.append(instruction)
        registry.sync(instructions)
        persistInstructions()
    }

    func updateInstruction(_ instruction: Instruction) {
        guard let index = instructions.firstIndex(where: { $0.id == instruction.id }) else { return }
        instructions[index] = instruction
        persistInstructions()
    }

    func deleteInstruction(_ instruction: Instruction) {
        KeyboardShortcuts.reset(KeyboardShortcuts.Name(instruction.shortcutKey))
        instructions.removeAll { $0.id == instruction.id }
        persistInstructions()
    }

    func moveInstructions(from offsets: IndexSet, to destination: Int) {
        instructions.move(fromOffsets: offsets, toOffset: destination)
        persistInstructions()
    }

    // MARK: - Settings

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
        } catch {
            notify("Couldn't update Launch at Login: \(error.localizedDescription)")
        }
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    // MARK: - History

    /// Records a completed rewrite (newest first), capped to `historyLimit`, then persists.
    private func recordHistory(before: String, after: String, instructionName: String, model: String, kind: HistoryKind) {
        record(HistoryEntry(kind: kind, instructionName: instructionName,
                            model: model, before: before, after: after))
    }

    /// Records a raw dictation — transcript only, no Claude model, no "before".
    private func recordRawDictation(transcript: String) {
        record(HistoryEntry(kind: .dictation, instructionName: "Dictation",
                            model: "", before: "", after: transcript))
    }

    /// Shared tail: honor `keepHistory`, prepend newest-first (capped), persist.
    private func record(_ entry: HistoryEntry) {
        guard keepHistory else { return }
        history = history.prepending(entry, cappedTo: historyLimit)
        persistHistory()
    }

    func clearHistory() {
        history = []
        persistHistory()
    }

    func deleteHistoryEntry(_ entry: HistoryEntry) {
        history.removeAll { $0.id == entry.id }
        persistHistory()
    }

    /// Re-inserts a just-deleted entry at its original position (supports Undo).
    func insertHistoryEntry(_ entry: HistoryEntry, at index: Int) {
        guard !history.contains(where: { $0.id == entry.id }) else { return }
        history.insert(entry, at: min(max(index, 0), history.count))
        if history.count > historyLimit { history = Array(history.prefix(historyLimit)) }
        persistHistory()
    }

    /// Writes a full snapshot to disk off the main actor so the UI never blocks on file I/O.
    private func persistHistory() {
        let snapshot = history
        Task.detached { HistoryStore.save(snapshot) }
    }

    /// Copies text to the clipboard so the user can paste a recovered before/after back in.
    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Persistence

    private func loadPersisted() {
        if !defaults.bool(forKey: Keys.seeded) {
            instructions = Instruction.defaults
            defaults.set(true, forKey: Keys.seeded)
            persistInstructions()
            // Bind "Auto Clean" (the first default) to ⇧⌘R out of the box.
            if let autoClean = instructions.first {
                KeyboardShortcuts.setShortcut(
                    .init(.r, modifiers: [.shift, .command]),
                    for: KeyboardShortcuts.Name(autoClean.shortcutKey)
                )
            }
        } else if let data = defaults.data(forKey: Keys.instructions),
                  let list = try? JSONDecoder().decode([Instruction].self, from: data) {
            instructions = list
            migrateAutoCleanIfNeeded()
        } else {
            instructions = Instruction.defaults
        }

        selectedModelID = defaults.string(forKey: Keys.selectedModel) ?? ""
        if let raw = defaults.string(forKey: Keys.rewriteProvider), let p = RewriteProvider(rawValue: raw) {
            rewriteProvider = p
        }
        fallbackEnabled = defaults.object(forKey: Keys.fallbackEnabled) as? Bool ?? false
        restoreClipboard = defaults.object(forKey: Keys.restoreClipboard) as? Bool ?? true
        keepHistory = defaults.object(forKey: Keys.keepHistory) as? Bool ?? true
        history = HistoryStore.load()
        playDictationTones = defaults.object(forKey: Keys.playDictationTones) as? Bool ?? true
        if let idString = defaults.string(forKey: Keys.dictationCleanupInstruction) {
            dictationCleanupInstructionID = UUID(uuidString: idString)
        }

        if let data = defaults.data(forKey: Keys.models),
           let list = try? JSONDecoder().decode([AnthropicModel].self, from: data) {
            models = list
        }
        modelsLastFetched = defaults.object(forKey: Keys.modelsFetched) as? Date
    }

    /// Bring an *unedited* Auto Clean instruction up to the current default so the strengthened wording
    /// reaches existing installs, not just fresh ones. A prompt the user has customized (anything other
    /// than the exact previous default) is left untouched.
    private func migrateAutoCleanIfNeeded() {
        guard let index = instructions.firstIndex(where: {
            $0.systemPrompt == Instruction.legacyAutoCleanPrompt
        }) else { return }
        instructions[index].systemPrompt = Instruction.autoCleanPrompt
        persistInstructions()
    }

    private func persistInstructions() {
        if let data = try? JSONEncoder().encode(instructions) {
            defaults.set(data, forKey: Keys.instructions)
        }
    }

    private func persistModels() {
        if let data = try? JSONEncoder().encode(models) {
            defaults.set(data, forKey: Keys.models)
        }
        defaults.set(modelsLastFetched, forKey: Keys.modelsFetched)
    }

    // MARK: - Spinner

    /// Advances `spinnerFrame` on a timer so the menu-bar icon visibly animates while working.
    private func startSpinner() {
        spinnerTask?.cancel()
        spinnerFrame = 0
        spinnerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 90_000_000) // ~11 fps
                guard let self, !Task.isCancelled else { break }
                self.spinnerFrame &+= 1
            }
        }
    }

    private func stopSpinner() {
        spinnerTask?.cancel()
        spinnerTask = nil
    }

    // MARK: - Setup pulse

    /// True when the menu-bar icon should show the "setup needed" state (and isn't busy with the
    /// recording/working animations, which take visual priority).
    private var isInSetupState: Bool {
        (needsSetup || dictationNeedsSetup) && !isWorking && !isRecording
    }

    /// Starts/stops the gentle "setup needed" pulse to match the current state. Called from the
    /// didSets of the inputs that feed `needsSetup`/`dictationNeedsSetup`, so the timer runs only
    /// while setup is genuinely pending and stops the instant it clears (preserving the app's
    /// "nothing polls once set up" property).
    private func updateSetupPulse() {
        if isInSetupState { startSetupPulse() } else { stopSetupPulse() }
    }

    private func startSetupPulse() {
        guard setupTask == nil else { return }   // already pulsing
        setupFrame = 0
        setupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 90_000_000) // ~11 fps
                guard let self, !Task.isCancelled else { break }
                self.setupFrame &+= 1
            }
        }
    }

    private func stopSetupPulse() {
        setupTask?.cancel()
        setupTask = nil
    }

    // MARK: - Error flash

    /// Beeps and briefly swaps the menu-bar icon to `nosign`, then reverts. Cancels any
    /// in-flight flash so rapid retries restart cleanly.
    private func startErrorFlash() {
        NSSound.beep()                 // respects the user's alert sound + UI-sound-effects setting
        flashTask?.cancel()
        showErrorFlash = true
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000) // ~0.9s
            guard let self, !Task.isCancelled else { return }
            self.showErrorFlash = false
            self.flashTask = nil
        }
    }

    /// Immediately clears the flash (used when a new rewrite starts or the modal escalates).
    private func cancelErrorFlash() {
        flashTask?.cancel()
        flashTask = nil
        showErrorFlash = false
    }

    /// Escalating feedback for a "no text selected" trigger: a quiet beep+flash for isolated
    /// failures, but the full explanatory modal once the user fails 3× in quick succession.
    /// Resets the streak after escalating so it doesn't nag on every subsequent failure.
    private func handleNoSelection() {
        let now = Date()
        if let last = lastNoSelectionFailure, now.timeIntervalSince(last) <= failureWindow {
            noSelectionFailureCount += 1
        } else {
            noSelectionFailureCount = 1
        }
        lastNoSelectionFailure = now

        if noSelectionFailureCount >= failureEscalationThreshold {
            noSelectionFailureCount = 0
            lastNoSelectionFailure = nil
            cancelErrorFlash()             // don't leave a stale glyph behind the modal
            notify("Couldn't read a selection. Select some text first, then trigger the rewrite.\n\nIf you just granted Accessibility access, quit and relaunch Dictidy for it to take effect.")
        } else {
            startErrorFlash()
        }
    }

    // MARK: - Notifications

    private func notify(_ message: String) {
        statusMessage = message
        // An accessory (menu-bar) app's alert can open behind other windows; activate and
        // float it so the user actually sees it.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Dictidy"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.window.level = .floating
        alert.window.makeKeyAndOrderFront(nil)
        alert.runModal()
    }
}
