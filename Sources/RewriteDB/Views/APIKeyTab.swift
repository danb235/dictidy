import SwiftUI

struct APIKeyTab: View {
    @EnvironmentObject var state: AppState
    @State private var key: String = KeychainService.load() ?? ""
    @State private var reveal = false

    private var trimmedKey: String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Anthropic API Key").font(.title3).bold()
            Text("Your key is stored in the macOS Keychain and only ever sent to api.anthropic.com.")
                .font(.callout).foregroundStyle(.secondary)

            HStack {
                Group {
                    if reveal {
                        TextField("sk-ant-…", text: $key)
                    } else {
                        SecureField("sk-ant-…", text: $key)
                    }
                }
                .textFieldStyle(.roundedBorder)

                Button(reveal ? "Hide" : "Show") { reveal.toggle() }
            }

            HStack {
                Button("Save API Key") {
                    state.saveAPIKey(trimmedKey)
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedKey.isEmpty)

                Button("Remove") {
                    state.removeAPIKey()
                    key = ""
                }
                .disabled(!state.hasAPIKey)

                Spacer()

                Link("Get API Key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
            }

            if state.hasAPIKey {
                Label("A key is saved. Saving also refreshes the model list.",
                      systemImage: "checkmark.seal.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }

            Spacer()
        }
        .padding()
    }
}
