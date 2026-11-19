import QotKit
import SwiftUI

/// One note, full screen, saving as you type, as in Apple Notes. A new note
/// (`noteID` nil) is created with its first non-blank text; a note left empty
/// is discarded (deleted) when you go back, as Notes does. A note that has
/// an attachment (a recording) isn't empty without text, and is kept; its
/// attachments show above the text (`AttachmentList`), and "Remove Audio"
/// in the menu takes a recording off the note and keeps the text.
struct NoteEditor: View {
    @Bindable var model: AppModel
    @State private var noteID: String?
    @State private var text: String
    /// The text as last saved, to tell typing apart from edits that arrive
    /// by sync while the note is open.
    @State private var saved: String
    @State private var pendingSave: Task<Void, Never>?
    @State private var dictation = Dictation()
    /// The text as it was when dictation started; what's heard goes after it.
    @State private var beforeDictation = ""
    /// The recording "Remove Audio" is asking about.
    @State private var removing: QotKit.Attachment?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, noteID: String?) {
        self.model = model
        let content = noteID.flatMap { model.note(id: $0)?.content } ?? ""
        _noteID = State(initialValue: noteID)
        _text = State(initialValue: content)
        _saved = State(initialValue: content)
    }

    private var note: NoteItem? { noteID.flatMap(model.note(id:)) }

    var body: some View {
        VStack(spacing: 0) {
            if let attachments = note?.attachments, !attachments.isEmpty {
                AttachmentList(attachments: attachments, model: model)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            TextEditor(text: $text)
                .focused($focused)
                .scrollDismissesKeyboard(.interactively)
                .contentMargins(.horizontal, 16, for: .scrollContent)
        }
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                "Remove the audio from this note?", isPresented: removingShown, titleVisibility: .visible,
                presenting: removing
            ) { attachment in
                Button("Remove Audio", role: .destructive) {
                    if let noteID {
                        model.removeAttachment(noteID: noteID, attachmentID: attachment.id)
                    }
                }
            } message: { _ in
                Text("The recording is deleted from all your devices. The note's text stays.")
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("More", systemImage: "ellipsis") {
                        ShareLink(item: text)
                        ForEach(note?.attachments.filter { $0.kind == "audio" } ?? [], id: \.id) { audio in
                            Button("Remove Audio", systemImage: "waveform.slash", role: .destructive) {
                                removing = audio
                            }
                        }
                        Button("Delete", systemImage: "trash", role: .destructive, action: delete)
                            .disabled(noteID == nil)
                    }
                }
                if focused {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done", systemImage: "checkmark") { focused = false }
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        if !dictation.listening { beforeDictation = text }
                        Task { await dictation.toggle() }
                    } label: {
                        Label(
                            dictation.listening ? "Stop Dictating" : "Dictate",
                            systemImage: dictation.listening ? "stop.circle.fill" : "mic")
                    }
                    .symbolEffect(.pulse, isActive: dictation.listening)
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    if let problem = dictation.problem {
                        Text(problem).font(.caption2).foregroundStyle(.secondary)
                    } else if let note {
                        Text("Edited \(note.updatedAt, format: .relative(presentation: .named))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.flexible, placement: .bottomBar)
            }
            .onAppear { if noteID == nil { focused = true } }
            .onChange(of: text) { scheduleSave() }
            .onChange(of: dictation.transcript) { _, heard in
                guard dictation.listening || !heard.isEmpty else { return }
                text = [beforeDictation, heard].filter { !$0.isEmpty }.joined(separator: " ")
            }
            .onChange(of: note?.content) { _, synced in
                // An edit from another device or process: take it unless
                // there is typing here that hasn't been saved yet.
                guard let synced, text == saved, synced != saved else { return }
                text = synced
                saved = synced
            }
            .onDisappear(perform: leave)
    }

    private var removingShown: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
        guard text != saved else { return }
        if let noteID {
            if model.update(id: noteID, content: text) != nil { saved = text }
        } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let created = model.create(text) {
                noteID = created.id
                saved = text
            }
        }
    }

    private func leave() {
        pendingSave?.cancel()
        if dictation.listening { dictation.stop() }
        let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if blank, note?.attachments.isEmpty ?? true {
            if let noteID { model.delete(id: noteID) }
        } else {
            save()
        }
    }

    private func delete() {
        pendingSave?.cancel()
        if let noteID { model.delete(id: noteID) }
        noteID = nil
        text = ""
        saved = ""
        dismiss()
    }
}

#Preview {
    let store = try? NoteStore(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let note = try? store?.add("Groceries\noat milk, eggs, sourdough\ncoffee beans")
    NavigationStack {
        NoteEditor(
            model: AppModel(store: store, credentials: MemoryCredentialStore()),
            noteID: note?.id)
    }
}
