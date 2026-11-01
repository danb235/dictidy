import AppKit
import AudioToolbox
import SwiftUI
import Combine
import KeyboardShortcuts
import DictidyKit

/// Which Settings tab to show — lets the menu deep-link to the relevant setup step.
enum SettingsTab: Hashable {
    case rewrite, instructions, dictation, general
}

/// Which dictation action a recording performs when it stops.
enum DictationMode { case raw, clean }

/// Central app state: instructions, live model list, selection, settings. Persists to
/// UserDefaults (instructions + cached models) and the Keychain (credentials), and wires the
/// global shortcuts to the rewrite flow.
@MainActor
final class AppState: ObservableObject {
    @Published var instructions: [Instruction] = []
    @Published var models: [RewriteModel] = [] { didSet { updateSetupPulse() } }
    @Published var modelsLastFetched: [RewriteProvider: Date] = [:]
    @Published var modelErrors: [RewriteProvider: String] = [:]
    @Published var refreshingProviders: Set<RewriteProvider> = []
    @Published var hasAnthropicAPIKey = false { didSet { updateSetupPulse() } }
    @Published var hasOpenAIAPIKey = false { didSet { updateSetupPulse() } }
    @Published var launchAtLogin: Bool = false
    @Published var isWorking: Bool = false {
        didSet {
            guard isWorking != oldValue else { return }
            if isWorking {
                cancelErrorFlash()
                cancelCancellationFlash()
                startSpinner()
            } else {
                stopSpinner()
            }
            updateEscapeMonitoring()
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
    /// Brief X glyph shown after Escape cancels recording, transcription, or rewriting.
    @Published var showCancellationFlash: Bool = false
    /// Live Accessibility-permission state. macOS posts no reliable change event, so we poll —
    /// but only while it's missing (see `startPermissionMonitorIfNeeded`), never once granted.
    @Published var accessibilityTrusted: Bool = AccessibilityPermissions.isTrusted { didSet { updateSetupPulse() } }
    /// Deep-link target when the menu opens the Settings window for a specific setup step.
    @Published var settingsTab: SettingsTab = .rewrite

    @Published var selectedModelID: String = "" {
        didSet { defaults.set(selectedModelID, forKey: Keys.selectedModel); updateSetupPulse() }
    }
    /// The shared **base** system prompt, composed in front of every instruction's style prompt at
    /// rewrite time. It carries the output mechanics (return only the rewritten text, treat the input as
    /// material, preserve meaning and language, and format the result) so each instruction is purely style.
    /// Editable in Settings; `resetBaseSystemPrompt()` restores the default.
    @Published var baseSystemPrompt: String = Instruction.baseSystemPromptDefault {
        didSet { defaults.set(baseSystemPrompt, forKey: Keys.baseSystemPrompt) }
    }

    @Published var restoreClipboard: Bool = true {
        didSet { defaults.set(restoreClipboard, forKey: Keys.restoreClipboard) }
    }
    /// Recorded before/after text of past rewrites (newest first), so the user can recover text
    /// they later lose. Persisted to a JSON file, not UserDefaults (see HistoryStore).
    @Published var history: [HistoryEntry] = []
    /// Session-only recovery buffer, independent of saved history and the system clipboard.
    @Published private(set) var lastGeneratedText: String?
    @Published var keepHistory: Bool = true {
        didSet { defaults.set(keepHistory, forKey: Keys.keepHistory) }
    }
    /// Dictation recording state; drives the menu-bar "listening" animation.
    @Published var isRecording: Bool = false {
        didSet {
            guard isRecording != oldValue else { return }
            if isRecording {
                cancelErrorFlash()
                cancelCancellationFlash()
                startRecordingAnimation()
            } else {
                stopRecordingAnimation()
            }
            updateEscapeMonitoring()
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
    let chatGPT = ChatGPTSignInService()
    private var chatGPTObservation: AnyCancellable?
    private let registry = ShortcutsRegistry()
    private let escapeKeyMonitor = EscapeKeyMonitor()
    private let defaults = UserDefaults.standard
    /// In-memory copies of API keys, read from the Keychain lazily on first use and cached for
    /// the app's lifetime. Reading the Keychain triggers a macOS authorization prompt, so we do
    /// it at most once per launch instead of on every rewrite. Kept in sync on save/remove.
    private var cachedAPIKeys: [RewriteProvider: String] = [:]
    private var refreshTokens: [RewriteProvider: UUID] = [:]
    private var spinnerTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    private var cancellationFlashTask: Task<Void, Never>?
    /// The current transcription/rewrite task. Retaining it lets Escape cancel network requests and
    /// ensures slower on-device work cannot paste a late result after the UI has returned to idle.
    private var processingTask: Task<Void, Never>?
    private var processingID: UUID?
    /// Rolling streak of consecutive no-selection failures; drives escalation to the modal.
    private var noSelectionFailureCount = 0
    private var lastNoSelectionFailure: Date?
    private let failureWindow: TimeInterval = 8            // rolling gap that keeps a streak alive
    private let failureEscalationThreshold = 3             // 3rd rapid failure → show the window
    private let historyLimit = 100                         // keep only the newest N rewrites
    private var whisperEngine: WhisperEngine?
    private var dictationMode: DictationMode?
    private var dictationCleanupConfiguration: RewriteConfiguration?
    private var recordingTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    /// Releases the resident speech model after a spell of inactivity so one-off dictation doesn't
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
        static let selectedModel = "selectedRewriteModelID"
        static let restoreClipboard = "restoreClipboard"
        static let models = "cachedRewriteModels"
        static let keepHistory = "keepHistory"
        static let playDictationTones = "playDictationTones"
        static let dictationCleanupInstruction = "dictationCleanupInstruction"
        static let baseSystemPrompt = "baseSystemPrompt"
        static let instructionDefaultsRevision = "instructionDefaultsRevision"
    }

    init() {
        loadPersisted()
        hasAnthropicAPIKey = KeychainService.exists(provider: .anthropic)
        hasOpenAIAPIKey = KeychainService.exists(provider: .openai)
        chatGPTObservation = chatGPT.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        chatGPT.onConnectionChanged = { [weak self] in self?.chatGPTConnectionChanged() }
        if !availableModels.isEmpty || configuredProviders.isEmpty { reconcileModelSelection() }
        launchAtLogin = LaunchAtLogin.isEnabled

        escapeKeyMonitor.onEscape = { [weak self] in self?.cancelActiveOperation() }

        registry.onTrigger = { [weak self] id in
            guard let self, let instruction = self.instructions.first(where: { $0.id == id }) else { return }
            self.runRewrite(instruction: instruction)
        }
        registry.sync(instructions)
        registry.onDictate = { [weak self] in self?.toggleDictation(mode: .raw) }
        registry.onDictateAndClean = { [weak self] in self?.toggleDictation(mode: .clean) }
        registry.registerStandalone()
        startPermissionMonitorIfNeeded()

        modelStore.onStatusChange = { [weak self] status in self?.modelStatus = status }
        modelStore.resolve()

        // Use cached catalogs at launch; read keys only for providers with no cached models.
        for provider in configuredProviders where !models.contains(where: { $0.provider == provider }) {
            Task { await refreshModels(for: provider) }
        }

        updateSetupPulse()   // start the attention pulse if the app launches needing setup
    }

    // MARK: - Setup status

    var needsSetup: Bool { !accessibilityTrusted || !rewriteReady }

    func hasAPIKey(for provider: RewriteProvider) -> Bool {
        switch provider {
        case .anthropic: return hasAnthropicAPIKey
        case .openai: return hasOpenAIAPIKey
        case .chatgpt: return false
        }
    }

    func isConfigured(_ provider: RewriteProvider) -> Bool {
        provider == .chatgpt ? chatGPT.isConnected : hasAPIKey(for: provider)
    }

    var configuredProviders: Set<RewriteProvider> {
        Set(RewriteProvider.allCases.filter { isConfigured($0) })
    }

    var availableModels: [RewriteModel] {
        RewriteProvider.allCases.flatMap { provider in
            let catalog = models.filter {
                $0.provider == provider && isConfigured(provider)
                    && (provider != .chatgpt || $0.connectionID == chatGPT.selectedAccountID)
            }
            return provider == .chatgpt ? catalog : catalog.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        }
    }

    var selectedModel: RewriteModel? { availableModels.first { $0.id == selectedModelID } }
    var rewriteReady: Bool { selectedModel != nil }
    var activeProviderLabel: String { selectedModel?.label ?? "" }

    private func reconcileModelSelection() {
        selectedModelID = RewriteModel.resolvedSelection(selectedModelID, models: models,
                                                         configuredProviders: configuredProviders)
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

    private func rewriteConfiguration(for instruction: Instruction) throws -> RewriteConfiguration {
        try RewriteConfiguration(instruction: instruction, defaultModelID: selectedModelID, models: availableModels,
                                 configuredProviders: configuredProviders, baseSystemPrompt: baseSystemPrompt)
    }

    private func configurationForAction(_ instruction: Instruction) -> RewriteConfiguration? {
        do { return try rewriteConfiguration(for: instruction) }
        catch {
            settingsTab = instruction.modelOverrideID == nil ? .rewrite : .instructions
            notify("Couldn't run \(instruction.name).\n\n\(error.localizedDescription)")
            return nil
        }
    }

    func runRewrite(instruction: Instruction) {
        guard !isWorking, !isRecording else { return }
        guard let configuration = configurationForAction(instruction) else { return }
        guard AccessibilityPermissions.isTrusted else {
            accessibilityTrusted = false
            startPermissionMonitorIfNeeded() // resume live polling while the user grants it
            notify("Dictidy needs Accessibility access to copy your selection and paste the result.\n\nEnable Dictidy in System Settings → Privacy & Security → Accessibility, then quit and relaunch Dictidy.")
            AccessibilityPermissions.prompt()
            return
        }

        let id = beginProcessing(status: "Rewriting…")
        processingTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishProcessing(id: id) }
            do {
                guard let selection = try await RewriteService.shared.captureSelection() else {
                    guard self.processingIsCurrent(id) else { return }
                    self.handleNoSelection()
                    return
                }
                guard self.processingIsCurrent(id) else { return }
                try await self.performRewrite(configuration: configuration, text: selection,
                                              before: selection, kind: .rewrite, processingID: id)
                guard self.processingIsCurrent(id) else { return }
                self.noSelectionFailureCount = 0
                self.lastNoSelectionFailure = nil
            } catch is CancellationError {
                // Escape already reset the UI and flashed the acknowledgement glyph.
            } catch {
                guard self.processingIsCurrent(id) else { return }
                self.notify(error.localizedDescription)
            }
        }
    }

    private struct DictationCleanupFailure: LocalizedError {
        let reason: String
        var errorDescription: String? {
            "Couldn't clean your dictation.\n\n\(reason)\n\nYour transcript is available through Paste Last Text."
        }
    }

    /// Use the captured instruction/model, preserving dictated source text if generation fails.
    private func performRewrite(configuration: RewriteConfiguration, text: String,
                                before: String, kind: HistoryKind, processingID: UUID) async throws {
        guard processingIsCurrent(processingID) else { throw CancellationError() }
        let result: String
        do {
            result = try await generate(configuration: configuration, text: text)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard processingIsCurrent(processingID) else { throw CancellationError() }
            if kind == .dictationClean {
                lastGeneratedText = text
                recordRawDictation(transcript: text)
                scheduleIdleUnload()
                throw DictationCleanupFailure(reason: error.localizedDescription)
            }
            throw error
        }
        guard processingIsCurrent(processingID) else { throw CancellationError() }
        try await pasteGeneratedText(result)
        guard processingIsCurrent(processingID) else { throw CancellationError() }
        recordHistory(before: before, after: result, instructionName: configuration.instruction.name,
                      model: configuration.model.label, kind: kind)
        scheduleIdleUnload()
    }

    /// Credentials and wire model IDs come from the captured model, never a mutable picker selection.
    private func generate(configuration: RewriteConfiguration, text: String) async throws -> String {
        try Task.checkCancellation()
        try configuration.validateAvailability(models: availableModels, configuredProviders: configuredProviders)
        let model = configuration.model
        let userText = rewriteInputMessage(text)
        switch model.provider {
        case .anthropic:
            let key = apiKey(for: .anthropic) ?? ""
            guard !key.isEmpty else { throw AnthropicError.missingAPIKey }
            return try await AnthropicClient(apiKey: key).rewrite(
                text: userText, systemPrompt: configuration.systemPrompt, model: model.modelID)
        case .openai:
            let key = apiKey(for: .openai) ?? ""
            guard !key.isEmpty else { throw OpenAIError.missingAPIKey }
            return try await OpenAIClient(apiKey: key).rewrite(
                text: userText, systemPrompt: configuration.systemPrompt, model: model.modelID)
        case .chatgpt:
            guard let accountID = model.connectionID else { throw ChatGPTError.notConnected }
            do {
                return try await chatGPT.authorized(accountID: accountID) { accessToken in
                    try await ChatGPTClient(accessToken: accessToken, connectionID: accountID)
                        .rewrite(text: userText, systemPrompt: configuration.systemPrompt, model: model.modelID,
                                 streamTransport: { try await ChatGPTHTTP.stream($0) })
                }
            } catch {
                if !(error is CancellationError) { modelErrors[.chatgpt] = error.localizedDescription }
                throw error
            }
        }
    }

    /// Re-run a History entry and copy the completed rewrite without changing the current selection.
    func rewriteAgain(_ text: String, instruction: Instruction) {
        guard !isWorking, !isRecording, !text.isEmpty else { return }
        guard let configuration = configurationForAction(instruction) else { return }
        let id = beginProcessing(status: "Rewriting…")
        processingTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishProcessing(id: id) }
            do {
                let result = try await self.generate(configuration: configuration, text: text)
                guard self.processingIsCurrent(id) else { return }
                self.lastGeneratedText = result
                self.recordHistory(before: text, after: result, instructionName: configuration.instruction.name,
                                   model: configuration.model.label, kind: .rewrite)
                self.copyToClipboard(result)
                self.scheduleIdleUnload()
            } catch {
                guard self.processingIsCurrent(id) else { return }
                self.notify(error.localizedDescription)
            }
        }
    }

    // MARK: - Text recovery

    /// Retain output before attempting the paste so a failed handoff can be retried without generating again.
    private func pasteGeneratedText(_ text: String) async throws {
        lastGeneratedText = text
        try await RewriteService.shared.paste(text, restoreClipboard: restoreClipboard)
    }

    func copyLastText() {
        guard !isWorking, !isRecording, let text = lastGeneratedText else { return }
        copyToClipboard(text)
    }

    func pasteLastText() {
        guard !isWorking, !isRecording, let text = lastGeneratedText else { return }
        guard AccessibilityPermissions.isTrusted else {
            accessibilityTrusted = false
            startPermissionMonitorIfNeeded()
            notify("Dictidy needs Accessibility access to paste text.\n\nEnable Dictidy in System Settings → Privacy & Security → Accessibility, then quit and relaunch Dictidy.")
            AccessibilityPermissions.prompt()
            return
        }
        // Capture synchronously while the menu action still belongs to the app the user was typing in.
        guard let target = RewriteService.shared.capturePasteTarget() else {
            notify("Click in the text box where you want the text, then choose Paste Last Text again.")
            return
        }
        let id = beginProcessing(status: "Pasting…")
        processingTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishProcessing(id: id) }
            do {
                try await RewriteService.shared.paste(text, restoreClipboard: self.restoreClipboard, to: target)
            } catch is CancellationError {
                // Escape cancels the retry without discarding the recovery buffer.
            } catch {
                guard self.processingIsCurrent(id) else { return }
                self.notify(error.localizedDescription)
            }
        }
    }

    /// Releases the resident Whisper model after `idleUnloadDelay` of no activity, so a
    /// single rewrite/dictation doesn't keep GBs mapped for the rest of the session. Setting the
    /// the engine to nil runs its deinit (whisper_free). Re-armed on each use.
    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.idleUnloadDelay)
            guard !Task.isCancelled, !self.isWorking, !self.isRecording else { return }
            self.whisperEngine = nil
            self.idleUnloadTask = nil
        }
    }

    // MARK: - Processing cancellation

    /// Starts one cancellable transcription/rewrite operation and returns the identity used to
    /// prevent a cancelled, slow on-device call from publishing a late result.
    private func beginProcessing(status: String) -> UUID {
        processingTask?.cancel()
        let id = UUID()
        processingID = id
        statusMessage = status
        isWorking = true
        return id
    }

    private func processingIsCurrent(_ id: UUID) -> Bool {
        processingID == id && !Task.isCancelled
    }

    private func finishProcessing(id: UUID) {
        guard processingID == id else { return }
        processingID = nil
        processingTask = nil
        statusMessage = nil
        isWorking = false
    }

    /// Handles the global Escape key. Recording audio is discarded immediately; in-flight work is
    /// cancelled and invalidated so even a synchronous C model call that is already running cannot
    /// paste or save its result when it eventually returns.
    private func cancelActiveOperation() {
        guard isRecording || isWorking else { return }

        if isRecording {
            isRecording = false
            stopWatchdog()
            DictationService.shared.cancel()
            dictationMode = nil
            dictationCleanupConfiguration = nil
            playTone(start: false)
        }

        if isWorking {
            processingID = nil
            processingTask?.cancel()
            processingTask = nil
            statusMessage = nil
            isWorking = false
        }

        startCancellationFlash()
    }

    /// Observe Escape only while it has an in-scope action, avoiding a permanent keyboard monitor.
    private func updateEscapeMonitoring() {
        if isRecording || isWorking {
            escapeKeyMonitor.start()
        } else {
            escapeKeyMonitor.stop()
        }
    }

    // MARK: - Dictation

    /// Recheck permission-dependent setup state after a system authorization prompt completes.
    func refreshPermissions() {
        accessibilityTrusted = AccessibilityPermissions.isTrusted
    }

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
        guard !isWorking, !isRecording else { return }
        let cleanupConfiguration: RewriteConfiguration?
        if mode == .clean, let instruction = dictationCleanupInstruction {
            do { cleanupConfiguration = try rewriteConfiguration(for: instruction) }
            catch RewriteConfigurationError.defaultModelUnavailable {
                // Retain raw dictation when cleanup has never been configured; an explicit override must work.
                cleanupConfiguration = nil
            } catch {
                settingsTab = .instructions
                notify("Couldn't start Dictate + Clean with \(instruction.name).\n\n\(error.localizedDescription)")
                return
            }
        } else {
            cleanupConfiguration = nil
        }
        playTone(start: true)   // before the engine grabs the mic, so the tone isn't clipped
        do {
            try DictationService.shared.start()
        } catch {
            notify("Couldn't start recording: \(error.localizedDescription)")
            return
        }
        dictationMode = mode
        dictationCleanupConfiguration = cleanupConfiguration
        isRecording = true
        preloadEngine(modelURL: modelURL)   // load the model while the user talks
        startWatchdog()
    }

    func stopAndProcess() {
        guard isRecording else { return }
        isRecording = false
        stopWatchdog()
        let mode = dictationMode ?? .clean
        let cleanupConfiguration = dictationCleanupConfiguration
        dictationMode = nil
        dictationCleanupConfiguration = nil
        let samples = DictationService.shared.stopAndCollect()
        playTone(start: false)   // after the tap is removed, so the tone isn't captured into the audio
        guard !samples.isEmpty else { startErrorFlash(); return }   // no audio captured

        let id = beginProcessing(status: "Transcribing…")
        processingTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishProcessing(id: id) }
            do {
                let engine = try await self.resolveEngine()
                let transcript = try await engine.transcribe(samples)
                guard self.processingIsCurrent(id) else { return }
                switch mode {
                case .raw:
                    try await self.pasteGeneratedText(transcript)
                    guard self.processingIsCurrent(id) else { return }
                    self.recordRawDictation(transcript: transcript)
                    self.scheduleIdleUnload()
                case .clean:
                    if let configuration = cleanupConfiguration {
                        self.statusMessage = "Cleaning…"
                        try await self.performRewrite(configuration: configuration, text: transcript,
                                                      before: transcript, kind: .dictationClean, processingID: id)
                    } else {
                        // No cleanup instruction or no rewrite provider set up — paste the raw transcript.
                        try await self.pasteGeneratedText(transcript)
                        guard self.processingIsCurrent(id) else { return }
                        self.recordRawDictation(transcript: transcript)
                        self.scheduleIdleUnload()
                    }
                }
            } catch WhisperEngine.EngineError.emptyTranscription {
                guard self.processingIsCurrent(id) else { return }
                self.startErrorFlash()   // silence / no speech — quiet feedback, no modal
            } catch is CancellationError {
                // Escape already reset the UI and flashed the acknowledgement glyph.
            } catch {
                guard self.processingIsCurrent(id) else { return }
                self.notify(error.localizedDescription)
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

    // MARK: - API keys and live catalogs

    private func apiKey(for provider: RewriteProvider) -> String? {
        if cachedAPIKeys[provider] == nil {
            cachedAPIKeys[provider] = KeychainService.load(provider: provider)
        }
        return cachedAPIKeys[provider]
    }

    @discardableResult
    func saveAPIKey(_ key: String, provider: RewriteProvider) -> Bool {
        guard RewriteProvider.apiKeyProviders.contains(provider) else { return false }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        do { try KeychainService.save(key, provider: provider) }
        catch { modelErrors[provider] = error.localizedDescription; return false }
        cachedAPIKeys[provider] = key
        refreshTokens[provider] = UUID()
        if provider == .anthropic { hasAnthropicAPIKey = true } else { hasOpenAIAPIKey = true }
        models.removeAll { $0.provider == provider }
        modelsLastFetched[provider] = nil
        modelErrors[provider] = nil
        persistModels()
        Task { await refreshModels(for: provider) }
        return true
    }

    func removeAPIKey(provider: RewriteProvider) {
        guard RewriteProvider.apiKeyProviders.contains(provider) else { return }
        do { try KeychainService.delete(provider: provider) }
        catch { modelErrors[provider] = error.localizedDescription; return }
        refreshTokens[provider] = UUID() // discard any response still arriving for the removed key
        refreshingProviders.remove(provider)
        cachedAPIKeys[provider] = nil
        if provider == .anthropic { hasAnthropicAPIKey = false } else { hasOpenAIAPIKey = false }
        models.removeAll { $0.provider == provider }
        modelsLastFetched[provider] = nil
        modelErrors[provider] = nil
        persistModels()
        reconcileModelSelection()
    }

    func refreshModels() async {
        await withTaskGroup(of: Void.self) { group in
            for provider in configuredProviders {
                group.addTask { await self.refreshModels(for: provider) }
            }
            await group.waitForAll()
        }
    }

    func refreshModels(for provider: RewriteProvider) async {
        guard isConfigured(provider) else {
            modelErrors[provider] = provider == .chatgpt ? ChatGPTError.notConnected.localizedDescription
                : "Add your \(provider.displayName) API key first."
            return
        }
        let token = UUID()
        refreshTokens[provider] = token
        refreshingProviders.insert(provider)
        modelErrors[provider] = nil
        defer {
            if refreshTokens[provider] == token { refreshingProviders.remove(provider) }
        }
        do {
            let list: [RewriteModel]
            switch provider {
            case .anthropic:
                let key = apiKey(for: .anthropic) ?? ""
                list = try await AnthropicClient(apiKey: key).listModels().map {
                    RewriteModel(provider: .anthropic, modelID: $0.id, displayName: $0.displayName)
                }
            case .openai:
                let key = apiKey(for: .openai) ?? ""
                list = try await OpenAIClient(apiKey: key).listModels()
            case .chatgpt:
                guard let accountID = chatGPT.selectedAccountID else { throw ChatGPTError.notConnected }
                list = try await chatGPT.authorized(accountID: accountID) { accessToken in
                    try await ChatGPTClient(accessToken: accessToken, connectionID: accountID,
                                           transport: { try await ChatGPTHTTP.session.data(for: $0) }).listModels()
                }
            }
            guard refreshTokens[provider] == token, isConfigured(provider) else { return }
            models.removeAll { $0.provider == provider }
            models.append(contentsOf: list)
            modelsLastFetched[provider] = Date()
            if list.isEmpty { modelErrors[provider] = "No text rewriting models are available for this connection." }
            persistModels()
            reconcileModelSelection()
        } catch {
            guard refreshTokens[provider] == token, isConfigured(provider) else { return }
            modelErrors[provider] = error.localizedDescription
        }
    }

    private func chatGPTConnectionChanged() {
        refreshTokens[.chatgpt] = UUID()
        refreshingProviders.remove(.chatgpt)
        models.removeAll { $0.provider == .chatgpt }
        modelsLastFetched[.chatgpt] = nil
        modelErrors[.chatgpt] = nil
        persistModels()
        reconcileModelSelection()
        if chatGPT.isConnected { Task { await refreshModels(for: .chatgpt) } }
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
        lastGeneratedText = nil
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
            defaults.set(Instruction.defaultsRevision, forKey: Keys.instructionDefaultsRevision)
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
            migrateDefaultInstructionsIfNeeded()
        } else {
            instructions = Instruction.defaults
            persistInstructions()
            defaults.set(Instruction.defaultsRevision, forKey: Keys.instructionDefaultsRevision)
        }

        // Upgrade the exact previous default; retain user-authored base instructions.
        baseSystemPrompt = Instruction.migratedBaseSystemPrompt(defaults.string(forKey: Keys.baseSystemPrompt))

        selectedModelID = RewriteModel.migratedSelection(saved: defaults.string(forKey: Keys.selectedModel),
            legacyAnthropicID: defaults.string(forKey: "selectedModelID"))
        restoreClipboard = defaults.object(forKey: Keys.restoreClipboard) as? Bool ?? true
        keepHistory = defaults.object(forKey: Keys.keepHistory) as? Bool ?? true
        history = HistoryStore.load()
        playDictationTones = defaults.object(forKey: Keys.playDictationTones) as? Bool ?? true
        if let idString = defaults.string(forKey: Keys.dictationCleanupInstruction) {
            dictationCleanupInstructionID = UUID(uuidString: idString)
        }
        if let id = dictationCleanupInstructionID, !instructions.contains(where: { $0.id == id }) {
            dictationCleanupInstructionID = nil
        }

        if let data = defaults.data(forKey: Keys.models),
           let list = try? JSONDecoder().decode([RewriteModel].self, from: data) {
            models = list
        } else if let data = defaults.data(forKey: "cachedModels"),
                  let list = try? JSONDecoder().decode([AnthropicModel].self, from: data) {
            models = list.map { RewriteModel(provider: .anthropic, modelID: $0.id, displayName: $0.displayName) }
        }
        for provider in RewriteProvider.allCases {
            modelsLastFetched[provider] = defaults.object(forKey: "modelsLastFetched." + provider.rawValue) as? Date
        }
        if modelsLastFetched[.anthropic] == nil {
            modelsLastFetched[.anthropic] = defaults.object(forKey: "modelsLastFetched") as? Date
        }

    }

    /// One-time defaults upgrade. Retire untouched presets and introduce Rewrite without replacing
    /// custom prompts or re-adding a default that the user subsequently deletes.
    private func migrateDefaultInstructionsIfNeeded() {
        guard defaults.integer(forKey: Keys.instructionDefaultsRevision) < Instruction.defaultsRevision else { return }
        let previous = instructions
        instructions = Instruction.migratedDefaults(previous)
        for removed in previous where !instructions.contains(where: { $0.id == removed.id }) {
            KeyboardShortcuts.reset(KeyboardShortcuts.Name(removed.shortcutKey))
        }
        if instructions != previous { persistInstructions() }
        defaults.set(Instruction.defaultsRevision, forKey: Keys.instructionDefaultsRevision)
    }

    /// Restores the base system prompt to its shipped default.
    func resetBaseSystemPrompt() { baseSystemPrompt = Instruction.baseSystemPromptDefault }

    private func persistInstructions() {
        if let data = try? JSONEncoder().encode(instructions) {
            defaults.set(data, forKey: Keys.instructions)
        }
    }

    private func persistModels() {
        if let data = try? JSONEncoder().encode(models) {
            defaults.set(data, forKey: Keys.models)
        }
        for provider in RewriteProvider.allCases {
            defaults.set(modelsLastFetched[provider], forKey: "modelsLastFetched." + provider.rawValue)
        }
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

    // MARK: - Cancellation flash

    /// Briefly swaps the menu-bar waveform for an X, confirming that Escape was received. Unlike an
    /// error flash this is silent: cancellation is an intentional action, not a failure.
    private func startCancellationFlash() {
        cancellationFlashTask?.cancel()
        showCancellationFlash = true
        cancellationFlashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000) // ~0.9s
            guard let self, !Task.isCancelled else { return }
            self.showCancellationFlash = false
            self.cancellationFlashTask = nil
        }
    }

    private func cancelCancellationFlash() {
        cancellationFlashTask?.cancel()
        cancellationFlashTask = nil
        showCancellationFlash = false
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
        let usageLimit = message.contains("[subscription_sharing_usage_limit_exceeded]")
        if usageLimit {
            alert.addButton(withTitle: "Manage usage")
            alert.addButton(withTitle: "OK")
        }
        alert.window.level = .floating
        alert.window.makeKeyAndOrderFront(nil)
        if alert.runModal() == .alertFirstButtonReturn && usageLimit {
            NSWorkspace.shared.open(ChatGPTSignInService.usageURL)
        }
    }
}
