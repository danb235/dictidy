import SwiftUI
import KeyboardShortcuts
import DictidyKit

/// Master-detail editor: the instruction list on the left, the selected instruction's editor on the
/// right, so selecting a row never reflows the layout. Each instruction has a name, a system prompt,
/// an optional model override, and an optional global shortcut.
struct InstructionsTab: View {
    @EnvironmentObject var state: AppState
    @State private var selection: UUID?
    @State private var showingPasteList = false
    @State private var pastedCorrections = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Each instruction appears in the menu bar and can have its own global shortcut. Its "
                 + "prompt describes only the style to apply. The base instructions and corrections below "
                 + "apply to every rewrite. Unlimited, free.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            baseInstructions
            correctionsSection

            HSplitView {
                master.frame(minWidth: 200, idealWidth: 230, maxWidth: 320)
                detail.frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .padding()
    }

    // MARK: - Base instructions (shared foundation)

    private var baseInstructions: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text("These apply to every rewrite, so each instruction is just the style on top. This is "
                     + "where the basics live, like preserving meaning, email formatting, and returning only the result.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $state.baseSystemPrompt)
                    .font(.body).frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                HStack {
                    Spacer()
                    Button("Reset to default") { state.resetBaseSystemPrompt() }
                        .disabled(state.baseSystemPrompt == Instruction.baseSystemPromptDefault)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Base instructions (applied to every rewrite)")
                .font(.subheadline).fontWeight(.medium)
        }
    }

    // MARK: - Corrections (words speech recognition gets wrong)

    private var correctionsSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text("Words or names that dictation gets wrong, and how to write them. Dictidy fixes them in "
                     + "every dictation and includes them in every rewrite.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !state.corrections.isEmpty {
                    HStack {
                        Text("Heard").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Write as").frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(width: 20, height: 1)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach($state.corrections) { $correction in
                                HStack {
                                    TextField("Heard", text: $correction.heard)
                                    TextField("Write as", text: $correction.replacement)
                                    Button { removeCorrection(correction.id) } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Remove")
                                    .frame(width: 20)
                                }
                                .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }
                HStack {
                    Button("Add") { state.corrections.append(Correction(heard: "", replacement: "")) }
                    Spacer()
                    Button("Paste a List…") { pastedCorrections = ""; showingPasteList = true }
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Corrections (applied to every dictation and rewrite)")
                .font(.subheadline).fontWeight(.medium)
        }
        .sheet(isPresented: $showingPasteList) { pasteListSheet }
    }

    private var pasteListSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste a List").font(.headline)
            Text("One per line, like Scott → Scot or VJ -> Vijay.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $pastedCorrections)
                .font(.body).frame(minWidth: 360, minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button("Cancel") { showingPasteList = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    state.corrections = Corrections.merge(Corrections.parse(pastedCorrections),
                                                          into: state.corrections)
                    showingPasteList = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(Corrections.parse(pastedCorrections).isEmpty)
            }
        }
        .padding()
    }

    private func removeCorrection(_ id: UUID) {
        state.corrections.removeAll { $0.id == id }
    }

    // MARK: - Master (list + add/duplicate)

    private var master: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(state.instructions) { instruction in
                    row(instruction).tag(instruction.id)
                }
                .onMove { state.moveInstructions(from: $0, to: $1) }
                .onDelete { offsets in offsets.map { state.instructions[$0] }.forEach(state.deleteInstruction) }
            }
            Divider()
            HStack(spacing: 12) {
                Button { addNew() } label: { Image(systemName: "plus") }
                    .help("New instruction")
                Button { duplicateSelected() } label: { Image(systemName: "plus.square.on.square") }
                    .help("Duplicate selected")
                    .disabled(selection == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    private func row(_ instruction: Instruction) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(instruction.name).fontWeight(.medium).lineLimit(1)
                if let shortcut = state.shortcutDescription(for: instruction) {
                    Text(shortcut).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if instruction.id == state.dictationCleanupInstruction?.id {
                Text("CLEANUP")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color.purple.opacity(0.22)))
                    .foregroundStyle(.purple)
                    .help("Used by Dictate + Clean")
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Detail (editor)

    @ViewBuilder private var detail: some View {
        if let id = selection, let binding = instructionBinding(for: id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Name", text: binding.name)
                        .textFieldStyle(.roundedBorder).font(.headline)

                    InstructionModelPicker(modelOverrideID: binding.modelOverrideID)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Style").font(.subheadline).foregroundStyle(.secondary)
                        TextEditor(text: binding.systemPrompt)
                            .font(.body).frame(minHeight: 140)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Global shortcut").font(.subheadline).foregroundStyle(.secondary)
                        KeyboardShortcuts.Recorder(for: KeyboardShortcuts.Name(binding.wrappedValue.shortcutKey))
                    }

                    HStack {
                        Spacer()
                        Button("Delete Instruction", role: .destructive) { deleteSelected() }
                    }
                }
                .padding()
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "text.badge.checkmark").font(.largeTitle).foregroundStyle(.secondary)
                Text("Select an instruction").font(.headline)
                Text("…or add a new one. Each can have its own name, model, prompt, and global shortcut.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        }
    }

    // MARK: - Actions

    private func addNew() {
        let instruction = Instruction(
            name: "New Instruction",
            // Style only. The base instructions supply the output mechanics.
            systemPrompt: "Apply this style. Rewrite the text to be clear and concise."
        )
        state.addInstruction(instruction)
        selection = instruction.id
    }

    private func duplicateSelected() {
        guard let id = selection, let original = state.instructions.first(where: { $0.id == id }) else { return }
        let copy = original.duplicated()
        state.addInstruction(copy)
        selection = copy.id
    }

    private func deleteSelected() {
        guard let id = selection, let instruction = state.instructions.first(where: { $0.id == id }) else { return }
        state.deleteInstruction(instruction)
        selection = nil
    }

    /// A two-way binding into the AppState array that persists on every edit.
    private func instructionBinding(for id: UUID) -> Binding<Instruction>? {
        guard state.instructions.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { state.instructions.first(where: { $0.id == id }) ?? Instruction(name: "", systemPrompt: "") },
            set: { state.updateInstruction($0) }
        )
    }
}

private struct InstructionModelPicker: View {
    @EnvironmentObject var state: AppState
    @Binding var modelOverrideID: String?

    private var overrideUnavailable: Bool {
        guard let id = modelOverrideID else { return false }
        return !state.availableModels.contains { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model").font(.subheadline).foregroundStyle(.secondary)
            Picker("Model", selection: $modelOverrideID) {
                Text("Use default — \(state.selectedModel?.label ?? "No model selected")")
                    .tag(nil as String?)
                if overrideUnavailable, let id = modelOverrideID {
                    Text("Unavailable · \(id)").tag(Optional(id)).disabled(true)
                }
                ForEach(RewriteProvider.allCases, id: \.self) { provider in
                    let models = state.availableModels.filter { $0.provider == provider }
                    if !models.isEmpty {
                        Section(provider.displayName) {
                            ForEach(models) { model in Text(model.label).tag(Optional(model.id)) }
                        }
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            if overrideUnavailable {
                Text("This model is unavailable. Choose another model or Use default. Check its API key or refresh models in Rewrite settings.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Applies wherever this instruction is used, including Dictate + Clean and History.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
