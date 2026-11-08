import QotKit
import SwiftUI

/// Where the notes list can go: an existing note, or a new one (keyed so
/// each compose opens a fresh editor).
enum Route: Hashable {
    case note(String)
    case new(UUID)
}

/// The notes list, as in Apple Notes: notes grouped by when they were last
/// edited, search, swipe to delete, and the compose button in the bottom
/// toolbar. Capture surfaces open a new note ready to type.
struct NotesView: View {
    @Bindable var model: AppModel
    @State private var path: [Route] = []
    @State private var query = ""
    @State private var showingAccount = false

    var body: some View {
        NavigationStack(path: $path) {
            list
                .navigationTitle("Notes")
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .note(let id): NoteEditor(model: model, noteID: id)
                    case .new: NoteEditor(model: model, noteID: nil)
                    }
                }
                .searchable(text: $query)
                .refreshable { await model.sync() }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Account", systemImage: "person.crop.circle") {
                            showingAccount = true
                        }
                    }
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        ListStatus(model: model).fixedSize()
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        Button("New Note", systemImage: "square.and.pencil", action: compose)
                    }
                }
        }
        .sheet(isPresented: $showingAccount) { AccountView(model: model) }
        // The Control Center control, the widgets and "New Note" open the
        // app ready to type.
        .onOpenURL { _ in compose() }
        .onReceive(NotificationCenter.default.publisher(for: OpenCaptureIntent.focusCapture)) { _ in
            compose()
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
        ) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    @ViewBuilder private var list: some View {
        let matching = NoteList.search(model.notes, for: query)
        let sections = NoteList.sections(matching, now: .now, calendar: .current)
        List {
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.notes) { note in
                        NavigationLink(value: Route.note(note.id)) {
                            NoteRow(note: note)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                model.delete(id: note.id)
                            }
                        }
                        .contextMenu {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                model.delete(id: note.id)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if model.notes.isEmpty {
                ContentUnavailableView {
                    Label("No Notes", systemImage: "note.text")
                } description: {
                    Text("Tap \(Image(systemName: "square.and.pencil")) to write one.")
                }
            } else if matching.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private func compose() {
        showingAccount = false
        path = [.new(UUID())]
    }
}

/// A note in the list: its title, then when it was edited and a preview.
struct NoteRow: View {
    let note: NoteItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(NoteList.title(of: note.content))
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(Self.edited(note.updatedAt))
                let preview = NoteList.preview(of: note.content)
                Text(preview.isEmpty ? "No additional text" : preview)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.subheadline)
        }
        .padding(.vertical, 2)
    }

    /// As Notes shows it: the time today, the weekday this week, else the date.
    static func edited(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }
}

/// The bottom toolbar's middle: how many notes, and whether they've reached
/// the server.
struct ListStatus: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Text(model.notes.count == 1 ? "1 Note" : "\(model.notes.count) Notes")
                .font(.caption)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String? {
        if model.session == nil {
            return "On this iPhone only"
        } else if model.syncProblem != nil {
            return "Not synced"
        } else if model.syncing {
            return "Syncing…"
        } else if model.unsynced > 0 {
            return "\(model.unsynced) not synced yet"
        }
        return nil
    }
}

#Preview {
    NotesView(
        model: AppModel(
            store: try? NoteStore(directory: .temporaryDirectory), credentials: MemoryCredentialStore()))
}
