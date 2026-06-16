import SwiftUI
import KeyboardShortcuts
import RewriteDBKit

struct InstructionsTab: View {
    @EnvironmentObject var state: AppState
    @State private var selection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Instruction Shortcuts").font(.title3).bold()
                Spacer()
                Button { addNew() } label: { Label("New", systemImage: "plus") }
            }
            Text("Each instruction appears in the menu bar and can have its own global shortcut. "
                 + "The system prompt tells Claude how to rewrite the selected text. "
                 + "Unlimited instructions, free.")
                .font(.callout).foregroundStyle(.secondary)

            List(selection: $selection) {
                ForEach(state.instructions) { instruction in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(instruction.name).fontWeight(.medium)
                            Text(instruction.systemPrompt)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        KeyboardShortcuts.Recorder(for: KeyboardShortcuts.Name(instruction.shortcutKey))
                    }
                    .tag(instruction.id)
                }
                .onMove { state.moveInstructions(from: $0, to: $1) }
                .onDelete { offsets in
                    offsets.map { state.instructions[$0] }.forEach(state.deleteInstruction)
                }
            }
            .frame(minHeight: 180)

            if let id = selection, let binding = instructionBinding(for: id) {
                Divider()
                Text("Edit “\(binding.wrappedValue.name)”").font(.headline)
                TextField("Name", text: binding.name)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: binding.systemPrompt)
                    .font(.body)
                    .frame(minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                HStack {
                    Spacer()
                    Button("Delete Instruction", role: .destructive) {
                        if let instruction = state.instructions.first(where: { $0.id == id }) {
                            state.deleteInstruction(instruction)
                            selection = nil
                        }
                    }
                }
            } else {
                Spacer()
            }
        }
        .padding()
    }

    private func addNew() {
        let instruction = Instruction(
            name: "New Instruction",
            systemPrompt: "Rewrite the text. Output only the rewritten text, with no preamble or explanation."
        )
        state.addInstruction(instruction)
        selection = instruction.id
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
