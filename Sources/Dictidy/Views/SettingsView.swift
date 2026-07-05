import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView(selection: $state.settingsTab) {
            RewriteTab()
                .tabItem { Label("Rewrite", systemImage: "wand.and.stars") }
                .tag(SettingsTab.rewrite)
            InstructionsTab()
                .tabItem { Label("Instructions", systemImage: "text.badge.checkmark") }
                .tag(SettingsTab.instructions)
            DictationTab()
                .tabItem { Label("Dictation", systemImage: "mic") }
                .tag(SettingsTab.dictation)
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
        }
        .padding()
        .frame(minWidth: 540, minHeight: 480)
    }
}
