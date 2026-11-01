import SwiftUI
import DictidyKit

struct RewriteTab: View {
    var body: some View {
        ScrollView { RewriteConfigurationView().padding() }
    }
}

/// Shared by Settings and onboarding: account connections and keys, one model selection.
struct RewriteConfigurationView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect your ChatGPT plan or add an Anthropic or OpenAI API key. Then choose your default model.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ChatGPTConnectionRow(connection: state.chatGPT)
            Divider()

            Picker("Default model", selection: $state.selectedModelID) {
                if !state.availableModels.contains(where: { $0.id == state.selectedModelID }) {
                    Text(state.selectedModelID.isEmpty ? "Choose a model" : "Selected model unavailable")
                        .tag(state.selectedModelID)
                }
                ForEach(RewriteProvider.allCases, id: \.self) { provider in
                    let models = state.availableModels.filter { $0.provider == provider }
                    if !models.isEmpty {
                        Section(provider.displayName) {
                            ForEach(models) { model in Text(model.label).tag(model.id) }
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            .disabled(state.availableModels.isEmpty)

            if state.selectedModel?.provider == .chatgpt {
                HStack {
                    Text("Using ChatGPT plan").font(.caption)
                    Link("Manage usage", destination: ChatGPTSignInService.usageURL).font(.caption)
                }
            } else if let model = state.selectedModel {
                Text("Uses your \(model.provider.displayName) API key and separate API billing.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Text("Instructions use this model unless you choose an override in Settings → Instructions.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button {
                    Task { await state.refreshModels() }
                } label: { Label("Refresh Models", systemImage: "arrow.clockwise") }
                .disabled(state.configuredProviders.isEmpty || !state.refreshingProviders.isEmpty)
                if !state.refreshingProviders.isEmpty { ProgressView().controlSize(.small) }
            }

            if state.availableModels.isEmpty {
                Text(state.configuredProviders.isEmpty ? "Connect ChatGPT or save an API key to load models." : "No models loaded yet. Refresh Models to try again.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            ForEach(RewriteProvider.apiKeyProviders, id: \.self) { provider in
                ProviderKeyRow(provider: provider)
                Divider()
            }
            Text("Selected text is sent to the provider of the model you choose. ChatGPT plan models use your plan or permitted ChatGPT credits. API-key models use separate API billing. Voice transcription runs on your Mac.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ChatGPTConnectionRow: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var connection: ChatGPTSignInService
    private var operationInProgress: Bool { state.isWorking || state.isRecording }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ChatGPT plan").font(.headline)
                if connection.isSigningIn {
                    StatusBadge(.working, label: "Waiting for sign-in…")
                } else if connection.isDisconnecting {
                    StatusBadge(.working, label: "Signing out…")
                } else if state.refreshingProviders.contains(.chatgpt) {
                    StatusBadge(.working, label: "Loading models…")
                } else if connection.isConnected {
                    StatusBadge(.ready, label: "Connected")
                }
            }
            Text("Use your ChatGPT Plus or Pro plan for rewrites. Available models and usage limits follow your account. This connection is currently in preview.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !connection.accounts.isEmpty {
                Picker("Account", selection: Binding(
                    get: { connection.selectedAccountID ?? "" },
                    set: { connection.selectAccount($0) }
                )) {
                    if connection.selectedAccountID == nil { Text("Choose an account").tag("") }
                    ForEach(connection.accounts) { account in Text(account.label).tag(account.id) }
                }
                .disabled(connection.isBusy || operationInProgress)
            }

            HStack {
                if connection.isSigningIn {
                    Button("Cancel sign-in") { connection.cancelSignIn() }
                } else if !connection.isConnected {
                    Button("Continue with ChatGPT") { connection.signIn() }
                        .disabled(connection.isBusy || operationInProgress)
                }
                if !connection.accounts.isEmpty {
                    Button("Add account") { connection.signIn(addAccount: true) }
                        .disabled(connection.isBusy || operationInProgress)
                }
                if connection.selectedAccount?.hasCredentials == true {
                    Button("Sign Out") { Task { await connection.disconnect() } }
                        .disabled(connection.isBusy || operationInProgress)
                }
                Spacer()
                Link("Manage usage", destination: ChatGPTSignInService.usageURL)
            }
            Text("Sign-in tokens stay in macOS Keychain. Choose a ChatGPT plan model below to use this connection.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = connection.message {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let error = state.modelErrors[.chatgpt] {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if let date = state.modelsLastFetched[.chatgpt], connection.isConnected {
                Text("\(state.availableModels.filter { $0.provider == .chatgpt }.count) models · Updated \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .alert("You're using your ChatGPT plan", isPresented: $connection.showPlanConfirmation) {
            Button("Got it") { }
        } message: {
            Text("Rewrites with a ChatGPT plan model use your plan or permitted ChatGPT credits. You can manage Dictidy's usage and access in ChatGPT settings.")
        }
    }
}

private struct ProviderKeyRow: View {
    @EnvironmentObject var state: AppState
    let provider: RewriteProvider
    // Do not decrypt existing keys just to display settings. Read each key only when its API is used.
    @State private var key = ""
    @State private var reveal = false
    private var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(provider.displayName + " API").font(.headline)
                if state.refreshingProviders.contains(provider) {
                    StatusBadge(.working, label: "Loading models…")
                } else if state.hasAPIKey(for: provider) {
                    StatusBadge(.ready, label: "Key saved")
                }
            }
            Text("Your key is stored in macOS Keychain and used only with \(provider.apiHost).")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Group {
                    if reveal { TextField(placeholder, text: $key) }
                    else { SecureField(placeholder, text: $key) }
                }.textFieldStyle(.roundedBorder)
                Button(reveal ? "Hide" : "Show") { reveal.toggle() }.disabled(key.isEmpty)
            }
            HStack {
                Button("Save API Key") {
                    if state.saveAPIKey(trimmedKey, provider: provider) { key = ""; reveal = false }
                }.disabled(trimmedKey.isEmpty)
                Button("Remove") {
                    state.removeAPIKey(provider: provider)
                    if !state.hasAPIKey(for: provider) { key = ""; reveal = false }
                }.disabled(!state.hasAPIKey(for: provider))
                Spacer()
                if let url = provider.keyURL { Link("Get API Key", destination: url) }
            }
            if let error = state.modelErrors[provider] {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if let date = state.modelsLastFetched[provider], state.hasAPIKey(for: provider) {
                Text("\(state.models.filter { $0.provider == provider }.count) models · Updated \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var placeholder: String {
        if state.hasAPIKey(for: provider) { return "Key saved. Paste a new key to replace it." }
        return provider == .anthropic ? "sk-ant-…" : "sk-…"
    }
}
