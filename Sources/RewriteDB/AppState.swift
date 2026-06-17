import AppKit
import SwiftUI
import KeyboardShortcuts
import RewriteDBKit

/// Which Settings tab to show — lets the menu deep-link to the relevant setup step.
enum SettingsTab: Hashable {
    case apiKey, model, instructions, general
}

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
            if isWorking { startSpinner() } else { stopSpinner() }
        }
    }
    @Published var statusMessage: String?
    /// Incrementing frame counter that drives the menu-bar spinner animation while working.
    @Published var spinnerFrame: Int = 0
    /// Live Accessibility-permission state. macOS posts no reliable change event, so we poll —
    /// but only while it's missing (see `startPermissionMonitorIfNeeded`), never once granted.
    @Published var accessibilityTrusted: Bool = AccessibilityPermissions.isTrusted
    /// Deep-link target when the menu opens the Settings window for a specific setup step.
    @Published var settingsTab: SettingsTab = .apiKey

    @Published var selectedModelID: String = "" {
        didSet { defaults.set(selectedModelID, forKey: Keys.selectedModel) }
    }
    @Published var restoreClipboard: Bool = true {
        didSet { defaults.set(restoreClipboard, forKey: Keys.restoreClipboard) }
    }

    private let registry = ShortcutsRegistry()
    private let defaults = UserDefaults.standard
    private var spinnerTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?

    private enum Keys {
        static let seeded = "didSeedDefaults"
        static let instructions = "instructions"
        static let selectedModel = "selectedModelID"
        static let restoreClipboard = "restoreClipboard"
        static let models = "cachedModels"
        static let modelsFetched = "modelsLastFetched"
    }

    init() {
        loadPersisted()
        hasAPIKey = (KeychainService.load()?.isEmpty == false)
        launchAtLogin = LaunchAtLogin.isEnabled

        registry.onTrigger = { [weak self] id in
            guard let self, let instruction = self.instructions.first(where: { $0.id == id }) else { return }
            Task { await self.runRewrite(instruction: instruction) }
        }
        registry.sync(instructions)
        startPermissionMonitorIfNeeded()

        if hasAPIKey {
            Task { await refreshModels() }
        }
    }

    // MARK: - Setup status

    /// True when the app can't actually perform a rewrite yet — drives the menu-bar warning
    /// state and the in-menu setup checklist.
    var needsSetup: Bool {
        !hasAPIKey || selectedModelID.isEmpty || !accessibilityTrusted
    }

    /// Human-readable shortcut for an instruction (e.g. "⇧⌘R"), or nil if none is bound.
    func shortcutDescription(for instruction: Instruction) -> String? {
        KeyboardShortcuts.getShortcut(for: KeyboardShortcuts.Name(instruction.shortcutKey))?.description
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
        guard !isWorking else { return }

        guard let key = KeychainService.load(), !key.isEmpty else {
            notify("No API key set. Open Settings → API Key.")
            return
        }
        guard !selectedModelID.isEmpty else {
            notify("No model selected. Open Settings → Model.")
            return
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
            notify("Couldn't read a selection. Select some text first, then trigger the rewrite.\n\nIf you just granted Accessibility access, quit and relaunch RewriteDB for it to take effect.")
            return
        }

        do {
            let client = AnthropicClient(apiKey: key)
            let result = try await client.rewrite(
                text: selection,
                systemPrompt: instruction.systemPrompt,
                model: selectedModelID
            )
            await RewriteService.shared.paste(result, restoreClipboard: restoreClipboard)
            isWorking = false
            statusMessage = nil
        } catch {
            isWorking = false
            statusMessage = nil
            notify(error.localizedDescription)
        }
    }

    // MARK: - API key

    func saveAPIKey(_ key: String) {
        KeychainService.save(key)
        hasAPIKey = true
        Task { await refreshModels() }
    }

    func removeAPIKey() {
        KeychainService.delete()
        hasAPIKey = false
        models = []
        persistModels()
    }

    // MARK: - Models

    func refreshModels() async {
        guard let key = KeychainService.load(), !key.isEmpty else {
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
        restoreClipboard = defaults.object(forKey: Keys.restoreClipboard) as? Bool ?? true

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
