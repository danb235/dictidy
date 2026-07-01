import SwiftUI
import RewriteDBKit

struct ModelTab: View {
    @EnvironmentObject var state: AppState
    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model").font(.title3).bold()
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

            Spacer()
        }
        .padding()
    }
}
