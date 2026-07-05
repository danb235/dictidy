import SwiftUI
import DictidyKit

/// One place to configure how selected text is rewritten: pick a primary provider (Claude API or the
/// on-device model), optionally enable fallback, and set up each provider. The primary provider is
/// shown expanded; the other collapses into a DisclosureGroup so the tab isn't a wall of controls.
struct RewriteTab: View {
    @EnvironmentObject var state: AppState
    @State private var key: String = KeychainService.load() ?? ""
    @State private var lastSavedKey: String = ""
    @State private var didLoadKey = false
    @State private var reveal = false
    @State private var isRefreshing = false

    private var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The field differs from what's saved — so "Save" is meaningful (else show a disabled "Saved").
    private var keyIsDirty: Bool { trimmedKey != lastSavedKey }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose how selected text is rewritten — the Claude API, an on-device model, or "
                     + "both with automatic fallback.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Primary", selection: $state.rewriteProvider) {
                    ForEach(RewriteProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Fall back to the other provider if the primary is unavailable",
                       isOn: $state.fallbackEnabled)
                Text(fallbackCaption)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                // Primary provider expanded; the other collapsed into a DisclosureGroup.
                let primary = state.rewriteProvider
                providerHeader(primary)
                body(for: primary)

                Divider()

                DisclosureGroup {
                    body(for: primary.other).padding(.top, 6)
                } label: {
                    providerHeader(primary.other)
                }
            }
            .padding()
        }
        .onAppear { if !didLoadKey { lastSavedKey = key; didLoadKey = true } }
    }

    // MARK: - Fallback caption

    private var fallbackCaption: String {
        let other = state.rewriteProvider.other
        guard state.fallbackEnabled else {
            return "Only \(state.rewriteProvider.displayName) is used."
        }
        let base = "If \(state.rewriteProvider.displayName) is unavailable, Dictidy uses \(other.displayName)."
        let otherReady = other == .anthropic ? state.anthropicReady : state.localModelReady
        return otherReady ? base : base + " Set it up below to enable this."
    }

    // MARK: - Provider header + body

    @ViewBuilder private func providerHeader(_ provider: RewriteProvider) -> some View {
        HStack(spacing: 8) {
            Text(provider == .anthropic ? "Anthropic (Claude) API" : "Local (on-device) model").font(.headline)
            providerBadge(provider)
            Spacer()
        }
    }

    @ViewBuilder private func providerBadge(_ provider: RewriteProvider) -> some View {
        switch provider {
        case .anthropic:
            if state.anthropicReady { StatusBadge(.ready) } else { StatusBadge(.actionNeeded, label: "Not set up") }
        case .local:
            switch state.localModelStatus {
            case .ready:       StatusBadge(.ready)
            case .downloading: StatusBadge(.working, label: "Downloading…")
            default:           StatusBadge(.actionNeeded, label: "Not downloaded")
            }
        }
    }

    @ViewBuilder private func body(for provider: RewriteProvider) -> some View {
        switch provider {
        case .anthropic: anthropicBody
        case .local:     localBody
        }
    }

    // MARK: - Anthropic (Claude) API

    @ViewBuilder private var anthropicBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your key is stored in the macOS Keychain and only ever sent to api.anthropic.com.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Group {
                    if reveal { TextField("sk-ant-…", text: $key) }
                    else { SecureField("sk-ant-…", text: $key) }
                }
                .textFieldStyle(.roundedBorder)
                Button(reveal ? "Hide" : "Show") { reveal.toggle() }
            }

            HStack {
                if state.hasAPIKey && !keyIsDirty {
                    Button("Saved") {}.disabled(true)
                } else {
                    Button("Save API Key") {
                        state.saveAPIKey(trimmedKey); lastSavedKey = trimmedKey
                    }
                    .buttonStyle(.borderedProminent).disabled(trimmedKey.isEmpty)
                }
                Button("Remove") { state.removeAPIKey(); key = ""; lastSavedKey = "" }
                    .disabled(!state.hasAPIKey)
                Spacer()
                Link("Get API Key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
            }

            if state.models.isEmpty {
                Text("No models loaded yet. Save your API key, then Refresh.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Model", selection: $state.selectedModelID) {
                    ForEach(state.models.sortedByDisplayName()) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .pickerStyle(.menu)
            }

            HStack(spacing: 10) {
                Button {
                    isRefreshing = true
                    Task { await state.refreshModels(); isRefreshing = false }
                } label: { Label("Refresh Models", systemImage: "arrow.clockwise") }
                    .disabled(isRefreshing || !state.hasAPIKey)

                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else if let date = state.modelsLastFetched {
                    Text("Updated \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Local (on-device)

    @ViewBuilder private var localBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Runs entirely on your Mac — no API key, and nothing leaves your device after the "
                 + "one-time download.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            localModelRow

            Text("Qwen3-4B-Instruct (Q4_K_M, ~2.5 GB). Loads on first use and unloads when idle to free memory.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var localModelRow: some View {
        switch state.localModelStatus {
        case .ready:
            StatusBadge(.ready, label: "Downloaded")
        case .missing:
            Button("Download model (~2.5 GB)") { state.localModelStore.download() }
                .buttonStyle(.borderedProminent)
        case .downloading(let progress):
            HStack(spacing: 10) {
                ProgressView(value: progress).frame(maxWidth: 220)
                Text("\(Int(progress * 100))%").font(.caption).monospacedDigit()
                Button("Cancel") { state.localModelStore.cancel() }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).font(.callout).foregroundStyle(.orange)
                Button("Retry download") { state.localModelStore.download() }
            }
        }
    }
}
