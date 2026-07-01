import Foundation
import SwiftUI
import RewriteDBKit

/// Browse past rewrites and copy either the before or the after back to the clipboard.
struct HistoryView: View {
    @EnvironmentObject var state: AppState
    @State private var selection: UUID?
    @State private var query = ""
    @State private var showClearConfirm = false
    @State private var undoEntry: HistoryEntry?
    @State private var undoIndex = 0

    /// History filtered by the search field (history is already newest-first).
    private var filtered: [HistoryEntry] {
        guard !query.isEmpty else { return state.history }
        let q = query.lowercased()
        return state.history.filter {
            $0.before.lowercased().contains(q)
                || $0.after.lowercased().contains(q)
                || $0.instructionName.lowercased().contains(q)
        }
    }

    /// Look up from the source of truth so a live delete never leaves a dangling detail.
    private var selectedEntry: HistoryEntry? {
        state.history.first { $0.id == selection }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(filtered) { entry in
                        row(entry)
                            .tag(entry.id)
                            .contextMenu {
                                Button("Copy Before") { state.copyToClipboard(entry.before) }
                                Button("Copy After") { state.copyToClipboard(entry.after) }
                                Divider()
                                Button("Delete", role: .destructive) { delete(entry) }
                            }
                    }
                }
                .onDeleteCommand { if let entry = selectedEntry { delete(entry) } } // ⌫ deletes selected

                Divider()
                HStack {
                    Text(countLabel).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) { showClearConfirm = true } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(state.history.isEmpty)
                    .help("Delete all saved rewrite history")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 340, max: 480)
            .searchable(text: $query, prompt: "Search history")
            .confirmationDialog("Delete all saved rewrite history?",
                                isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("Clear History", role: .destructive) {
                    state.clearHistory()
                    selection = nil
                }
                Button("Cancel", role: .cancel) {}
            }
        } detail: {
            detailPane
        }
        .overlay(alignment: .bottom) { undoToast }
        .animation(.easeInOut(duration: 0.2), value: undoEntry?.id)
    }

    // MARK: - Detail

    @ViewBuilder private var detailPane: some View {
        if let entry = selectedEntry {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        InstructionBadge(name: entry.instructionName)
                        Text(entry.date.formatted(date: .abbreviated, time: .standard))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(entry.model).font(.caption).foregroundStyle(.tertiary)
                }

                HSplitView {
                    CopyableTextSection(title: "Before", text: entry.before, onCopy: state.copyToClipboard,
                                        shortcut: KeyboardShortcut("c", modifiers: [.command, .shift]))
                        .frame(minWidth: 240)
                        .padding(.trailing, 10)
                    CopyableTextSection(title: "After", text: entry.after, onCopy: state.copyToClipboard,
                                        shortcut: KeyboardShortcut("c", modifiers: .command))
                        .frame(minWidth: 240)
                        .padding(.leading, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack {
                    Spacer()
                    Button("Delete", role: .destructive) { delete(entry) }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if state.history.isEmpty {
            message("clock.arrow.circlepath", "No rewrites yet",
                    "They'll appear here after you run a rewrite.")
        } else {
            message("sidebar.left", "Select a rewrite",
                    "Choose an entry on the left to see its before and after.")
        }
    }

    // MARK: - Sidebar row

    private func row(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(preview(entry.before))
                .lineLimit(2)
                .font(.callout)
            HStack(spacing: 6) {
                InstructionBadge(name: entry.instructionName)
                Spacer()
                Text(Self.relativeFormatter.localizedString(for: entry.date, relativeTo: Date()))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Undo toast

    @ViewBuilder private var undoToast: some View {
        if let entry = undoEntry {
            HStack(spacing: 12) {
                Text("Deleted “\(preview(entry.before))”").lineLimit(1)
                Button("Undo") { performUndo() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.quaternary))
            .shadow(radius: 8, y: 2)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Actions

    private func delete(_ entry: HistoryEntry) {
        let index = state.history.firstIndex { $0.id == entry.id } ?? 0
        if selection == entry.id { selection = nil }
        state.deleteHistoryEntry(entry)
        undoEntry = entry
        undoIndex = index
        let id = entry.id
        Task { // auto-dismiss the undo toast after a few seconds
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if undoEntry?.id == id { undoEntry = nil }
        }
    }

    private func performUndo() {
        guard let entry = undoEntry else { return }
        state.insertHistoryEntry(entry, at: undoIndex)
        selection = entry.id
        undoEntry = nil
    }

    // MARK: - Helpers

    private var countLabel: String {
        let count = state.history.count
        return count == 0 ? "" : "\(count) rewrite\(count == 1 ? "" : "s")"
    }

    private func message(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    /// Trims whitespace and any leading bullet/dash so previews start on real content.
    private func preview(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = s.first, "•*-–—".contains(first) {
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    /// Compact, single-unit relative time ("1 min ago") — avoids the truncated two-unit default.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

/// A small colored capsule for an instruction name; the color is stable per name.
private struct InstructionBadge: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.caption2).fontWeight(.semibold)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.22)))
            .foregroundStyle(color)
    }

    /// Deterministic hue from the name (djb2) so a given instruction keeps its color across launches.
    private var color: Color {
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return Color(hue: Double(hash % 360) / 360.0, saturation: 0.55, brightness: 0.85)
    }
}

/// A titled, read-only, scrollable text block that fills its space, with a Copy button
/// (optionally bound to a keyboard shortcut) that briefly confirms.
private struct CopyableTextSection: View {
    let title: String
    let text: String
    let onCopy: (String) -> Void
    var shortcut: KeyboardShortcut?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                copyButton
            }
            ScrollView {
                Text(text.isEmpty ? "—" : text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var copyButton: some View {
        let button = Button {
            onCopy(text)
            withAnimation { copied = true }
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                withAnimation { copied = false }
            }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .disabled(text.isEmpty)

        if let shortcut {
            button.keyboardShortcut(shortcut)
        } else {
            button
        }
    }
}
