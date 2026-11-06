import QotKit
import SwiftUI

/// Capture at the top, newest notes below. Opening the app puts the cursor
/// in the field, so capturing is: open, type, return.
struct NotesView: View {
    @Bindable var model: AppModel
    @State private var draft = ""
    @State private var showingAccount = false
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
                } footer: {
                    SyncStatus(model: model)
                }
            }
            .refreshable { await model.sync() }
            .navigationTitle("qot")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Account", systemImage: "person.crop.circle") { showingAccount = true }
                }
            }
            .sheet(isPresented: $showingAccount) { AccountView(model: model) }
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

/// One quiet line under the notes: whether they've reached the server.
struct SyncStatus: View {
    let model: AppModel

    var body: some View {
        if model.session == nil {
            Text("Notes stay on this device until you sign in.")
        } else if let problem = model.syncProblem {
            Label("Not synced: \(problem)", systemImage: "icloud.slash")
        } else if model.syncing {
            Text("Syncing…")
        } else if model.unsynced > 0 {
            Text("\(model.unsynced) not synced yet")
        }
    }
}

#Preview {
    NotesView(model: AppModel(store: try? NoteStore(directory: .temporaryDirectory), credentials: MemoryCredentialStore()))
}
