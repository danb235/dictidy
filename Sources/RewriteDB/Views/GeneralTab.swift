import SwiftUI

struct GeneralTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Startup").font(.title3).bold()
            Toggle("Launch RewriteDB at login", isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            ))
            Text("Automatically start RewriteDB when you log in to your Mac.")
                .font(.callout).foregroundStyle(.secondary)

            Divider()

            Text("Behavior").font(.title3).bold()
            Toggle("Restore clipboard after rewriting", isOn: $state.restoreClipboard)
            Text("Puts your previous clipboard contents back after the rewrite is pasted.")
                .font(.callout).foregroundStyle(.secondary)

            Divider()

            Text("Permissions").font(.title3).bold()
            HStack {
                Button("Open Accessibility Settings") {
                    AccessibilityPermissions.openSettings()
                }
                Text(AccessibilityPermissions.isTrusted ? "Granted" : "Not granted")
                    .font(.callout)
                    .foregroundStyle(AccessibilityPermissions.isTrusted ? .green : .orange)
            }
            Text("RewriteDB needs Accessibility access to copy your selection and paste the result back.")
                .font(.callout).foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
    }
}
