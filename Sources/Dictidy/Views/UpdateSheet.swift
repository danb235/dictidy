import SwiftUI

/// The "Check for Updates" window — checking / up-to-date / available (with release notes) / error.
struct UpdateView: View {
    @EnvironmentObject var updater: Updater
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch updater.status {
            case .idle, .checking:
                centered { ProgressView("Checking for updates…") }

            case .downloading:
                centered { ProgressView("Downloading update…") }

            case .upToDate:
                centered {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.green)
                        Text("You're up to date").font(.headline)
                        Text("Dictidy \(updater.currentVersion)").font(.callout).foregroundStyle(.secondary)
                    }
                }

            case .failed(let message):
                centered {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                        Text("Couldn't check for updates").font(.headline)
                        Text(message).font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        Button("Try Again") { updater.check(force: true) }
                    }
                }

            case .available(let release):
                VStack(alignment: .leading, spacing: 12) {
                    Text("Update available").font(.title3).bold()
                    Text("Dictidy \(release.version) — you have \(updater.currentVersion).")
                        .font(.callout).foregroundStyle(.secondary)
                    Divider()
                    ScrollView {
                        Text(renderedNotes(release.notes))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    Divider()
                    HStack {
                        Spacer()
                        Button("Later") { dismiss() }
                        Button("Install & Relaunch") { updater.install() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 460, height: 460)
    }

    /// Render the release-notes markdown inline (bold/links/bullets), preserving line breaks.
    private func renderedNotes(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }

    @ViewBuilder private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
