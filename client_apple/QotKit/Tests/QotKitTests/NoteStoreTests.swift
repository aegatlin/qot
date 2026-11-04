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

    @Test func aCorruptNoteFileIsAnErrorNotAnEmptyNote() throws {
        let (store, dir) = try tempStore()
        try store.add("get milk")
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("notes/bad.note"))
        #expect(throws: NoteStoreError.self) { try store.list() }
    }
}
