import QotKit
import SwiftUI

/// Capture at the top, newest notes below. Opening the app puts the cursor
/// in the field, so capturing is: open, type, return.
struct NotesView: View {
    @State var model: NotesModel
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Capture a thought", text: $draft, axis: .vertical)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .onChange(of: draft) { _, new in
                            // Return in a vertical field inserts a newline;
                            // treat it as "save" like the CLI's one-liner.
                            if new.hasSuffix("\n") {
                                draft.removeLast()
                                save()
                            }
                        }
                }
                Section {
                    ForEach(model.notes) { note in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.content)
                            Text(note.createdAt, format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { model.notes[$0] }.forEach(model.delete)
                    }
                }
            }
            .navigationTitle("qot")
            .onAppear { focused = true }
            .alert(
                "Something went wrong",
                isPresented: Binding(
                    get: { model.error != nil }, set: { if !$0 { model.error = nil } })
            ) {
                Button("OK") { model.error = nil }
            } message: {
                Text(model.error ?? "")
            }
        }
    }

    private func save() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if model.add(draft) { draft = "" }
    }
}

#Preview {
    NotesView(model: NotesModel.onDevice())
}
