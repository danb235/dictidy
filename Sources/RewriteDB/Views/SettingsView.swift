import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView(selection: $state.settingsTab) {
            APIKeyTab()
                .tabItem { Label("API Key", systemImage: "key") }
                .tag(SettingsTab.apiKey)
            ModelTab()
                .tabItem { Label("Model", systemImage: "cpu") }
                .tag(SettingsTab.model)
            InstructionsTab()
                .tabItem { Label("Instructions", systemImage: "text.badge.checkmark") }
                .tag(SettingsTab.instructions)
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
        }
        .padding()
    }
}
