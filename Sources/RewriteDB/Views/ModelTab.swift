import SwiftUI
import RewriteDBKit

struct ModelTab: View {
    @EnvironmentObject var state: AppState
    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model").font(.title3).bold()

            Picker("Rewrite with", selection: $state.rewriteProvider) {
                ForEach(RewriteProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)

            switch state.rewriteProvider {
            case .anthropic: anthropicSection
            case .local:     localSection
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Anthropic (API)

    @ViewBuilder private var anthropicSection: some View {
        Text("The list is fetched live from Anthropic, so it stays current automatically — "
             + "retired models drop off and new ones appear without updating the app.")
            .font(.callout).foregroundStyle(.secondary)

        if state.models.isEmpty {
            Text("No models loaded yet. Add your API key, then Refresh.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Picker("Selected model", selection: $state.selectedModelID) {
                ForEach(state.models.sortedByDisplayName()) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
            .pickerStyle(.menu)
        }

        HStack(spacing: 10) {
            Button {
                isRefreshing = true
                Task {
                    await state.refreshModels()
                    isRefreshing = false
                }
            } label: {
                Label("Refresh Models", systemImage: "arrow.clockwise")
            }
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
        Text("Run rewrites entirely on your Mac — no API key, and nothing leaves your device after "
             + "the one-time download.")
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
            Label("Downloaded", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
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
