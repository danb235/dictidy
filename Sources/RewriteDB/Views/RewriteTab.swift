import SwiftUI
import RewriteDBKit

/// One place to configure how selected text is rewritten: pick a primary provider (Claude API or the
/// on-device model), optionally enable fallback, and set up each provider. Merges the former
/// API Key and Model tabs. Scrolls, since both provider sections are always shown.
struct RewriteTab: View {
    @EnvironmentObject var state: AppState
    @State private var key: String = KeychainService.load() ?? ""
    @State private var reveal = false
    @State private var isRefreshing = false

    private var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

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

                anthropicSection

                Divider()

                localSection
            }
            .padding()
        }
    }

    // MARK: - Fallback caption

    private var fallbackCaption: String {
        let other = state.rewriteProvider.other
        guard state.fallbackEnabled else {
            return "Only \(state.rewriteProvider.displayName) is used."
        }
        let base = "If \(state.rewriteProvider.displayName) is unavailable, RewriteDB uses \(other.displayName)."
        let otherReady = other == .anthropic ? state.anthropicReady : state.localModelReady
        return otherReady ? base : base + " Set up \(other.displayName) below to enable this."
    }

    // MARK: - Anthropic (Claude) API

    @ViewBuilder private var anthropicSection: some View {
        sectionHeader("Anthropic (Claude) API", ready: state.anthropicReady)
        Text("Your key is stored in the macOS Keychain and only ever sent to api.anthropic.com.")
            .font(.callout).foregroundStyle(.secondary)

        HStack {
            Group {
                if reveal { TextField("sk-ant-…", text: $key) }
                else { SecureField("sk-ant-…", text: $key) }
            }
            .textFieldStyle(.roundedBorder)
            Button(reveal ? "Hide" : "Show") { reveal.toggle() }
        }

        HStack {
            Button("Save API Key") { state.saveAPIKey(trimmedKey) }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedKey.isEmpty)
            Button("Remove") { state.removeAPIKey(); key = "" }
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

    // MARK: - Local (on-device)

    @ViewBuilder private var localSection: some View {
        sectionHeader("Local (on-device) model", ready: state.localModelReady)
        Text("Runs entirely on your Mac — no API key, and nothing leaves your device after the "
             + "one-time download.")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        localModelRow

        Text("Qwen3-4B-Instruct (Q4_K_M, ~2.5 GB). Loads on first use and unloads when idle to free memory.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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

    // MARK: - Helpers

    private func sectionHeader(_ title: String, ready: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.headline)
            if ready { StatusBadge(.ready) }
        }
    }
}
