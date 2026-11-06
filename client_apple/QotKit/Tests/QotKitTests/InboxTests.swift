import Foundation
import Testing

@testable import QotKit

@Suite struct InboxTests {
    @Test func aCaptureBecomesANote() throws {
        let store = try NoteStore(directory: tempDir())
        let note = try Inbox(store: store).receive(["id": "w1", "text": "get milk"])
        #expect(note?.content == "get milk")
        #expect(try store.list().map(\.content) == ["get milk"])
    }

    @Test func theSameCaptureTwiceIsOneNote() throws {
        let store = try NoteStore(directory: tempDir())
        let inbox = Inbox(store: store)
        try inbox.receive(["id": "w1", "text": "get milk"])
        #expect(try inbox.receive(["id": "w1", "text": "get milk"]) == nil)
        // Even after a relaunch.
        #expect(try Inbox(store: store).receive(["id": "w1", "text": "get milk"]) == nil)
        #expect(try store.list().count == 1)
    }

    @Test func somethingThatIsntACaptureIsAnError() throws {
        let inbox = Inbox(store: try NoteStore(directory: tempDir()))
        #expect(throws: InboxError.self) { try inbox.receive(["text": "no id"]) }
        #expect(throws: NoteStoreError.blank) { try inbox.receive(["id": "w2", "text": " "]) }
    }

    @Test func itRemembersOnlyRecentIds() throws {
        let store = try NoteStore(directory: tempDir())
        let inbox = Inbox(store: store, remember: 3)
        for i in 1...5 { try inbox.receive(["id": "w\(i)", "text": "note \(i)"]) }
        #expect(try inbox.seen() == ["w3", "w4", "w5"])
    }
}
