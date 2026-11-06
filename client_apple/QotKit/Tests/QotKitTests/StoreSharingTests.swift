import Foundation
import Testing

@testable import QotKit

@Suite struct StoreSharingTests {
    @Test func syncStateStartsEmptyAndRoundTrips() throws {
        let store = try NoteStore(directory: tempDir())
        #expect(try store.loadSyncState().cursor() == 0)

        let note = try store.add("get milk")
        let pushed = markPushed(
            state: try store.loadSyncState(), sent: planPush(notes: try store.allNotes(), state: .empty()))
        try store.saveSyncState(pushed)
        #expect(try store.unsyncedCount() == 0)
        _ = note
    }

    @Test func syncStateUsesTheCLIFileName() throws {
        let dir = tempDir()
        let store = try NoteStore(directory: dir)
        try store.saveSyncState(.empty())
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sync.json").path))
        try store.forgetSyncState()
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("sync.json").path))
        try store.forgetSyncState()  // forgetting twice is fine
    }

    @Test func aCorruptSyncStateIsAnErrorNotAFreshStart() throws {
        let dir = tempDir()
        let store = try NoteStore(directory: dir)
        try Data("{".utf8).write(to: dir.appendingPathComponent("sync.json"))
        #expect(throws: NoteStoreError.self) { try store.loadSyncState() }
    }

    @Test func unsyncedCountsNotesWithChangesNotPushed() throws {
        let store = try NoteStore(directory: tempDir())
        try store.add("get milk")
        try store.add("call mom")
        #expect(try store.unsyncedCount() == 2)
    }

    @Test func mergeKeepsEditsMadeOnDiskMeanwhile() throws {
        // A pull read the note, then the person deleted it, then the pull
        // saves its version: the delete must survive.
        let store = try NoteStore(directory: tempDir())
        let item = try store.add("get milk")
        let stale = try #require(try store.allNotes().first)
        try store.delete(id: item.id)
        try store.merge([stale])
        #expect(try store.list().isEmpty)
    }

    @Test func migrationMovesNotesIntoTheSharedStore() throws {
        let oldDir = tempDir()
        let old = try NoteStore(directory: oldDir)
        let a = try old.add("get milk")
        let b = try old.add("call mom")

        let shared = try NoteStore(directory: tempDir())
        let c = try shared.add("already here")
        try shared.migrate(from: oldDir)

        #expect(Set(try shared.list().map(\.id)) == [a.id, b.id, c.id])
        #expect(try old.list().isEmpty)
        // Running it again is harmless.
        try shared.migrate(from: oldDir)
        #expect(try shared.list().count == 3)
    }

    @Test func migratingFromNowhereIsANoOp() throws {
        let shared = try NoteStore(directory: tempDir())
        try shared.migrate(from: tempDir())
        #expect(try shared.list().isEmpty)
    }

    @Test func migrationMergesANoteBothStoresHave() throws {
        let oldDir = tempDir()
        let old = try NoteStore(directory: oldDir)
        let item = try old.add("get milk")
        let shared = try NoteStore(directory: tempDir())
        try shared.merge(try old.allNotes())
        try old.delete(id: item.id)

        try shared.migrate(from: oldDir)
        #expect(try shared.list().isEmpty)  // the delete came along
    }
}
