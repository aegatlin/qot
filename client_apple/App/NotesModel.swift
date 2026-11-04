import Foundation
import Observation
import QotKit

/// The app's view of the note store. Every action saves first; errors are
/// shown, never swallowed.
@MainActor @Observable
final class NotesModel {
    private let store: NoteStore?
    private(set) var notes: [NoteItem] = []
    var error: String?

    init(store: NoteStore?, error: String? = nil) {
        self.store = store
        self.error = error
        reload()
    }

    /// The store in this app's Application Support directory.
    static func onDevice() -> NotesModel {
        do {
            let dir = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            return NotesModel(store: try NoteStore(directory: dir))
        } catch {
            return NotesModel(store: nil, error: error.localizedDescription)
        }
    }

    /// Saves a note. Returns whether it was saved, so the field can clear.
    func add(_ content: String) -> Bool {
        perform { _ = try $0.add(content) }
    }

    func delete(_ note: NoteItem) {
        perform { try $0.delete(id: note.id) }
    }

    func reload() {
        perform { _ in }
    }

    @discardableResult
    private func perform(_ action: (NoteStore) throws -> Void) -> Bool {
        guard let store else { return false }
        do {
            try action(store)
            notes = try store.list().reversed()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}
