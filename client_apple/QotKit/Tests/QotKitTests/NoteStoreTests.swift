import Foundation
import Testing

@testable import QotKit

/// Every test gets its own temporary store and never touches a real one.
private func tempStore() throws -> (NoteStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("qotkit-\(UUID().uuidString)")
    return (try NoteStore(directory: dir), dir)
}

@Suite struct NoteStoreTests {
    @Test func addedNotesAreListedOldestFirst() throws {
        let (store, _) = try tempStore()
        try store.add("get milk")
        try store.add("call mom")
        #expect(try store.list().map(\.content) == ["get milk", "call mom"])
    }

    @Test func notesPersistAcrossStores() throws {
        let (store, dir) = try tempStore()
        let note = try store.add("get milk")
        let reopened = try NoteStore(directory: dir)
        #expect(try reopened.list() == [note])
    }

    @Test func notesUseTheCLIStoreLayout() throws {
        let (store, dir) = try tempStore()
        let note = try store.add("get milk")
        let file = dir.appendingPathComponent("notes/\(note.id).note")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func deleteHidesTheNoteButKeepsItsTombstone() throws {
        let (store, dir) = try tempStore()
        let note = try store.add("get milk")
        try store.delete(id: note.id)
        #expect(try store.list().isEmpty)
        let file = dir.appendingPathComponent("notes/\(note.id).note")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func deletingAnUnknownNoteIsAnError() throws {
        let (store, _) = try tempStore()
        #expect(throws: NoteStoreError.self) { try store.delete(id: "nope") }
    }

    @Test func blankNotesAreRejected() throws {
        let (store, _) = try tempStore()
        #expect(throws: NoteStoreError.self) { try store.add("  \n") }
        #expect(try store.list().isEmpty)
    }

    @Test func createdAtComesFromTheId() throws {
        let (store, _) = try tempStore()
        let before = Date()
        let note = try store.add("get milk")
        #expect(abs(note.createdAt.timeIntervalSince(before)) < 5)
    }

    @Test func updateChangesTheContentAndKeepsTheNote() throws {
        let (store, dir) = try tempStore()
        let note = try store.add("get milk")
        let edited = try store.update(id: note.id, content: "get oat milk")
        #expect(edited.id == note.id)
        #expect(edited.content == "get oat milk")
        #expect(try NoteStore(directory: dir).list().map(\.content) == ["get oat milk"])
    }

    @Test func updateMergesWithWhatIsOnDisk() throws {
        // Another process (an intent, a sync) wrote since this one read: an
        // edit is applied to the note on disk, not to a stale copy.
        let (store, dir) = try tempStore()
        let note = try store.add("milk")
        let other = try NoteStore(directory: dir)
        try other.update(id: note.id, content: "oat milk")
        let edited = try store.update(id: note.id, content: "oat milk, eggs")
        #expect(edited.content == "oat milk, eggs")
    }

    @Test func aNoteMayBeEditedToBlank() throws {
        // The editor saves as you type; clearing a note to retype it is
        // normal. Whether to discard an empty note is the UI's call.
        let (store, _) = try tempStore()
        let note = try store.add("get milk")
        #expect(try store.update(id: note.id, content: "").content == "")
    }

    @Test func updatingAnUnknownNoteIsAnError() throws {
        let (store, _) = try tempStore()
        #expect(throws: NoteStoreError.self) { try store.update(id: "nope", content: "x") }
    }

    @Test func updatedAtIsTheLastEdit() throws {
        let (store, _) = try tempStore()
        let note = try store.add("get milk")
        #expect(note.updatedAt >= note.createdAt.addingTimeInterval(-1))
        #expect(abs(note.updatedAt.timeIntervalSinceNow) < 5)
    }

    @Test func aCorruptNoteFileIsAnErrorNotAnEmptyNote() throws {
        let (store, dir) = try tempStore()
        try store.add("get milk")
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("notes/bad.note"))
        #expect(throws: NoteStoreError.self) { try store.list() }
    }
}
