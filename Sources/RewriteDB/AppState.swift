import AppKit
import SwiftUI
import KeyboardShortcuts
import RewriteDBKit

/// Which Settings tab to show — lets the menu deep-link to the relevant setup step.
enum SettingsTab: Hashable {
    case apiKey, model, instructions, general, dictation
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
    @Published var hasAPIKey: Bool = false
    @Published var launchAtLogin: Bool = false
    @Published var isWorking: Bool = false {
        didSet {
            guard isWorking != oldValue else { return }
            if isWorking { cancelErrorFlash(); startSpinner() } else { stopSpinner() }
        }
    }
    @Published var statusMessage: String?
    /// Incrementing frame counter that drives the menu-bar spinner animation while working.
    @Published var spinnerFrame: Int = 0
    /// When true, the menu-bar icon briefly shows the `nosign` glyph to signal a
    /// no-selection failure — a lightweight, non-modal alternative to the alert.
    @Published var showErrorFlash: Bool = false
    /// Live Accessibility-permission state. macOS posts no reliable change event, so we poll —
    /// but only while it's missing (see `startPermissionMonitorIfNeeded`), never once granted.
    @Published var accessibilityTrusted: Bool = AccessibilityPermissions.isTrusted
    /// Deep-link target when the menu opens the Settings window for a specific setup step.
    @Published var settingsTab: SettingsTab = .apiKey

    @Published var selectedModelID: String = "" {
        didSet { defaults.set(selectedModelID, forKey: Keys.selectedModel) }
    }
    /// Which backend performs rewrites. Anthropic by default; `local` uses the on-device model.
    @Published var rewriteProvider: RewriteProvider = .anthropic {
        didSet { defaults.set(rewriteProvider.rawValue, forKey: Keys.rewriteProvider) }
    }
    /// Mirror of the local rewrite model download/readiness status, for the Model settings UI.
    @Published var localModelStatus: LocalLLMModelStore.Status = .missing
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
        }
    }
    /// Frame counter driving the listening pulse (like `spinnerFrame` drives the working spinner).
    @Published var recordingFrame: Int = 0
    /// Mirror of the Whisper model download/readiness status, for the Dictation settings UI.
    @Published var modelStatus: WhisperModelStore.Status = .missing
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

    private enum Keys {
        static let seeded = "didSeedDefaults"
        static let instructions = "instructions"
        static let selectedModel = "selectedModelID"
        static let rewriteProvider = "rewriteProvider"
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
    }

    // MARK: - Setup status

    /// True when the app can't actually perform a rewrite yet — drives the menu-bar warning
    /// state and the in-menu setup checklist. Provider-aware: the Anthropic path needs a key +
    /// model; the local path needs the on-device model downloaded. Accessibility is needed by both.
    var needsSetup: Bool {
        if !accessibilityTrusted { return true }
        switch rewriteProvider {
        case .anthropic: return !hasAPIKey || selectedModelID.isEmpty
        case .local:     return !localModelReady
        }
    }

    /// Whether the on-device rewrite model is downloaded and ready.
    var localModelReady: Bool {
        if case .ready = localModelStatus { return true }
        return false
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

        switch rewriteProvider {
        case .anthropic:
            guard apiKey()?.isEmpty == false else {
                notify("No API key set. Open Settings → API Key.")
                return
            }
            guard !selectedModelID.isEmpty else {
                notify("No model selected. Open Settings → Model.")
                return
            }
        case .local:
            guard localModelReady else {
                settingsTab = .model
                notify("The local rewrite model isn't installed yet.\n\nOpen Settings → Model, choose “Local (on-device)”, and download it (about 2.5 GB), then try again.")
                return
            }
        }
        guard AccessibilityPermissions.isTrusted else {
            accessibilityTrusted = false
            startPermissionMonitorIfNeeded() // resume live polling while the user grants it
            notify("RewriteDB needs Accessibility access to copy your selection and paste the result.\n\nEnable RewriteDB in System Settings → Privacy & Security → Accessibility, then quit and relaunch RewriteDB.")
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

        await performRewrite(text: selection, instruction: instruction, before: selection, kind: .rewrite)
        noSelectionFailureCount = 0
        lastNoSelectionFailure = nil
        isWorking = false
        statusMessage = nil
    }

    /// Runs `text` through the active provider (Anthropic or the on-device model) with
    /// `instruction`, records history (before/after), and pastes the result at the cursor. Caller
    /// owns isWorking/statusMessage. Shared by the selection rewrite and Dictate + Clean.
    private func performRewrite(text: String, instruction: Instruction, before: String, kind: HistoryKind) async {
        do {
            let result: String
            let modelName: String
            switch rewriteProvider {
            case .anthropic:
                guard let key = apiKey(), !key.isEmpty else {
                    notify("No API key set. Open Settings → API Key.")
                    return
                }
                result = try await AnthropicClient(apiKey: key).rewrite(
                    text: text, systemPrompt: instruction.systemPrompt, model: selectedModelID)
                modelName = models.first(where: { $0.id == selectedModelID })?.displayName ?? selectedModelID
            case .local:
                let engine = try await resolveLocalEngine()
                result = try await engine.rewrite(text: text, systemPrompt: instruction.systemPrompt)
                modelName = LocalLLMModelStore.modelDisplayName
            }
            recordHistory(before: before, after: result, instructionName: instruction.name, model: modelName, kind: kind)
            await RewriteService.shared.paste(result, restoreClipboard: restoreClipboard)
            scheduleIdleUnload()
        } catch {
            notify(error.localizedDescription)
        }
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
            notify("RewriteDB needs Accessibility access to paste dictated text.\n\nEnable RewriteDB in System Settings → Privacy & Security → Accessibility, then quit and relaunch RewriteDB.")
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
            notify("Microphone access is off.\n\nEnable RewriteDB in System Settings → Privacy & Security → Microphone, then try again.")
            MicrophonePermissions.openSettings()
        }
    }

    private func beginRecording(mode: DictationMode, modelURL: URL) {
        do {
            try DictationService.shared.start()
        } catch {
            notify("Couldn't start recording: \(error.localizedDescription)")
            return
        }
        dictationMode = mode
        isRecording = true
        playTone(start: true)
        preloadEngine(modelURL: modelURL)   // load the model while the user talks
        startWatchdog()
    }

    func stopAndProcess() {
        guard isRecording else { return }
        isRecording = false
        stopWatchdog()
        playTone(start: false)
        let mode = dictationMode ?? .clean
        let samples = DictationService.shared.stopAndCollect()
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
                    if let instruction = dictationCleanupInstruction {
                        statusMessage = "Cleaning…"
                        await performRewrite(text: transcript, instruction: instruction,
                                             before: transcript, kind: .dictationClean)
                    } else {
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
        NSSound(named: start ? "Tink" : "Pop")?.play()
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
        } else {
            instructions = Instruction.defaults
        }

        selectedModelID = defaults.string(forKey: Keys.selectedModel) ?? ""
        if let raw = defaults.string(forKey: Keys.rewriteProvider), let p = RewriteProvider(rawValue: raw) {
            rewriteProvider = p
        }
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
            notify("Couldn't read a selection. Select some text first, then trigger the rewrite.\n\nIf you just granted Accessibility access, quit and relaunch RewriteDB for it to take effect.")
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
        alert.messageText = "RewriteDB"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.window.level = .floating
        alert.window.makeKeyAndOrderFront(nil)
        alert.runModal()
    }
}
