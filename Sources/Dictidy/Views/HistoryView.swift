import Foundation
import SwiftUI
import DictidyKit

/// Browse past rewrites and dictations, and copy any of the text back to the clipboard.
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
                    .help("Delete all saved history")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 340, max: 480)
            .searchable(text: $query, prompt: "Search history")
            .confirmationDialog("Delete all saved history?",
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
                        KindBadge(kind: entry.kind)
                        if entry.kind != .dictation {
                            InstructionBadge(name: entry.instructionName)
                        }
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        rewriteAgainMenu(for: entry)
                    }
                    if !entry.model.isEmpty {
                        Text(entry.model).font(.caption).foregroundStyle(.tertiary)
                    }
                }

                if entry.kind == .dictation {
                    // Raw dictation has no before/after — show just the transcript.
                    CopyableTextSection(title: "Transcript", text: entry.after, onCopy: state.copyToClipboard,
                                        shortcut: KeyboardShortcut("c", modifiers: .command))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Word-level diff: removed words red on Before, added words green on After.
                    let diff = WordDiff.diff(before: entry.before, after: entry.after)
                    HSplitView {
                        CopyableTextSection(title: "Before", text: entry.before, onCopy: state.copyToClipboard,
                                            shortcut: KeyboardShortcut("c", modifiers: [.command, .shift]),
                                            attributed: beforeAttributed(diff))
                            .frame(minWidth: 240)
                            .padding(.trailing, 10)
                        CopyableTextSection(title: "After", text: entry.after, onCopy: state.copyToClipboard,
                                            shortcut: KeyboardShortcut("c", modifiers: .command),
                                            attributed: afterAttributed(diff), prominentCopy: true)
                            .frame(minWidth: 240)
                            .padding(.leading, 10)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                HStack {
                    Spacer()
                    Button("Delete", role: .destructive) { delete(entry) }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if state.history.isEmpty {
            message("clock.arrow.circlepath", "No history yet",
                    "Rewrites and dictations you run will appear here.")
        } else {
            message("sidebar.left", "Select an entry",
                    "Choose an entry on the left to see its text.")
        }
    }

    // MARK: - Sidebar row

    private func row(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                // Kind as a compact leading glyph, so the badge no longer truncates the preview.
                Image(systemName: entry.kind == .rewrite ? "wand.and.stars" : "mic")
                    .font(.caption).foregroundStyle(.secondary)
                Text(previewText(entry))
                    .lineLimit(2)
                    .font(.callout)
            }
            HStack(spacing: 6) {
                if entry.kind != .dictation {
                    InstructionBadge(name: entry.instructionName)
                }
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
                Text("Deleted “\(previewText(entry))”").lineLimit(1)
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
        return count == 0 ? "" : "\(count) item\(count == 1 ? "" : "s")"
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

    /// Text to preview for a row/toast — raw dictation has no "before", so use the transcript.
    private func previewText(_ entry: HistoryEntry) -> String {
        preview(entry.kind == .dictation ? entry.after : entry.before)
    }

    // MARK: - Diff styling + rewrite-again

    /// Before pane: unchanged text plain, removed words in red (git-diff style).
    private func beforeAttributed(_ tokens: [DiffToken]) -> AttributedString {
        var s = AttributedString()
        for token in tokens where token.kind != .inserted {
            var run = AttributedString(token.text)
            if token.kind == .deleted { run.foregroundColor = .red }
            s += run
        }
        return s
    }

    /// After pane: unchanged text plain, added words in green.
    private func afterAttributed(_ tokens: [DiffToken]) -> AttributedString {
        var s = AttributedString()
        for token in tokens where token.kind != .deleted {
            var run = AttributedString(token.text)
            if token.kind == .inserted { run.foregroundColor = .green }
            s += run
        }
        return s
    }

    /// Re-run an entry's source text through any instruction (using the active provider). The result
    /// is recorded to History and copied to the clipboard.
    @ViewBuilder private func rewriteAgainMenu(for entry: HistoryEntry) -> some View {
        let source = entry.kind == .dictation ? entry.after : entry.before
        Menu {
            ForEach(state.instructions) { instruction in
                Button(instruction.name) {
                    state.rewriteAgain(source, instruction: instruction)
                }
            }
        } label: {
            Label("Rewrite again", systemImage: "arrow.clockwise")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(state.isWorking || source.isEmpty)
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

/// A fixed-label, fixed-color capsule naming what produced a history entry.
private struct KindBadge: View {
    let kind: HistoryKind

    var body: some View {
        Text(label)
            .font(.caption2).fontWeight(.semibold)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.22)))
            .foregroundStyle(color)
    }

    private var label: String {
        switch kind {
        case .rewrite:        return "Rewrite"
        case .dictation:      return "Dictation"
        case .dictationClean: return "Dictation + Clean"
        }
    }

    private var color: Color {
        switch kind {
        case .rewrite:        return .blue
        case .dictation:      return .green
        case .dictationClean: return .purple
        }
    }
}

/// A titled, read-only, scrollable text block that fills its space, with a Copy button
/// (optionally bound to a keyboard shortcut) that briefly confirms.
private struct CopyableTextSection: View {
    let title: String
    let text: String
    let onCopy: (String) -> Void
    var shortcut: KeyboardShortcut?
    /// When set, renders this styled string (e.g. the word diff) instead of `text`; Copy still copies `text`.
    var attributed: AttributedString?
    /// Emphasize the Copy button (the "After" pane's primary action).
    var prominentCopy = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                copyButton
            }
            ScrollView {
                content
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var content: some View {
        if let attributed {
            Text(attributed)
        } else {
            Text(text.isEmpty ? "—" : text)
        }
    }

    private var copyButton: some View {
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

        let styled: AnyView = prominentCopy ? AnyView(button.buttonStyle(.borderedProminent)) : AnyView(button)
        return Group {
            if let shortcut { styled.keyboardShortcut(shortcut) } else { styled }
        }
    }
}
