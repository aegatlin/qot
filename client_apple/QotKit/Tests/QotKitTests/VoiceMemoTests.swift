import Foundation
import Testing

@testable import QotKit

/// One device: a store, its keychain stand-in and a client of `server`.
private struct Device {
    let store: NoteStore
    let credentials: MemoryCredentialStore
    let syncer: Syncer

    init(_ server: FakeServer, signedIn creds: Credentials? = signedIn()) throws {
        store = try NoteStore(directory: tempDir())
        credentials = MemoryCredentialStore(creds)
        syncer = Syncer(store: store, credentials: credentials) { base in
            ServerAPI(baseURL: base, transport: server, userAgent: "qot-ios/test")
        }
    }

    /// Records a memo: a file somewhere temporary, handed to the store.
    @discardableResult
    func record(_ transcript: String?, bytes: Data = recordingBytes) throws -> NoteItem {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-\(UUID().uuidString).m4a")
        try bytes.write(to: file)
        return try store.addMemo(
            recording: file, mediaType: "audio/mp4", durationMs: 42_000, transcript: transcript)
    }
}

private let recordingBytes = Data([0, 1, 2, 255, 254, 3])

@Suite struct VoiceMemoTests {
    // MARK: - The store

    @Test func aMemoIsANoteWithItsTranscriptAndItsRecordingBesideIt() throws {
        let phone = try Device(FakeServer())
        let memo = try phone.record("call the plumber")

        #expect(memo.content == "call the plumber")
        let audio = try #require(memo.attachments.first)
        #expect(audio.kind == "audio")
        #expect(audio.mediaType == "audio/mp4")
        #expect(audio.size == UInt64(recordingBytes.count))
        #expect(audio.durationMs == 42_000)
        #expect(audio.text == .done)
        #expect(try phone.store.list() == [memo])
        // The recording is moved into the store, in the CLI-style layout.
        let file = phone.store.directory.appendingPathComponent("blobs/\(audio.id)")
        #expect(try Data(contentsOf: file) == recordingBytes)
        #expect(try phone.store.blobIDs() == [audio.id])
        #expect(phone.store.localBlob(audio.id) == file)
    }

    @Test func aMemoWithNoTranscriptYetWaitsForOne() throws {
        let phone = try Device(FakeServer())
        let memo = try phone.record(nil)
        let audio = try #require(memo.attachments.first)
        #expect(memo.content == "")
        #expect(audio.text == .pending)
        #expect(!memo.isEmpty)
        #expect(try phone.store.pendingTranscripts().map(\.attachment.id) == [audio.id])

        let filled = try phone.store.fillTranscript(
            noteID: memo.id, attachmentID: audio.id, text: "call the plumber")
        #expect(filled.content == "call the plumber")
        #expect(filled.attachments.first?.text == .done)
        #expect(try phone.store.pendingTranscripts().isEmpty)
        // A second transcription of the same recording adds nothing.
        let again = try phone.store.fillTranscript(
            noteID: memo.id, attachmentID: audio.id, text: "call the plumber")
        #expect(again.content == "call the plumber")
    }

    @Test func aMemoThatHeardNothingIsStillSaved() throws {
        let phone = try Device(FakeServer())
        let memo = try phone.record("")
        #expect(memo.content == "")
        #expect(memo.attachments.first?.text == .done)
        #expect(try phone.store.list().count == 1)
    }

    @Test func aMissingRecordingFileSavesNothing() throws {
        let phone = try Device(FakeServer())
        let nowhere = FileManager.default.temporaryDirectory.appendingPathComponent("nope.m4a")
        #expect(throws: (any Error).self) {
            try phone.store.addMemo(
                recording: nowhere, mediaType: "audio/mp4", durationMs: 1, transcript: "x")
        }
        #expect(try phone.store.list().isEmpty)
        #expect(try phone.store.blobIDs().isEmpty)
    }

    @Test func titlesAndSearchKnowAboutRecordings() throws {
        let phone = try Device(FakeServer())
        let spoken = try phone.record("call the plumber\nabout the sink")
        let silent = try phone.record("")
        #expect(NoteList.title(of: spoken) == "call the plumber")
        #expect(NoteList.title(of: silent) == "Voice Memo 0:42")
        #expect(NoteList.title(of: NoteItem(id: "x", content: " ", createdAt: .now)) == "New Note")
        #expect(NoteList.search([spoken, silent], for: "voice memo") == [silent])
        #expect(NoteList.search([spoken, silent], for: "sink") == [spoken])
    }

    @Test func onlyANoteWithNoTextAndNoAttachmentsIsEmpty() throws {
        let phone = try Device(FakeServer())
        #expect(try phone.record("").isEmpty == false)
        #expect(NoteItem(id: "x", content: " \n", createdAt: .now).isEmpty)
        #expect(!NoteItem(id: "x", content: "milk", createdAt: .now).isEmpty)
    }

    @Test func removingTheRecordingKeepsTheText() throws {
        let phone = try Device(FakeServer())
        let memo = try phone.record("call the plumber")
        let audio = try #require(memo.attachments.first)

        let textOnly = try phone.store.removeAttachment(noteID: memo.id, attachmentID: audio.id)
        #expect(textOnly.content == "call the plumber")
        #expect(textOnly.attachments.isEmpty)
        #expect(try phone.store.blobIDs().isEmpty)
    }

    @Test func clearingTheTextKeepsTheRecording() throws {
        let phone = try Device(FakeServer())
        let memo = try phone.record("um")
        let cleared = try phone.store.update(id: memo.id, content: "")
        #expect(cleared.attachments == memo.attachments)
        #expect(!cleared.isEmpty)
    }

    @Test func deletingAMemoRemovesItsRecordingFromThisDevice() throws {
        let phone = try Device(FakeServer())
        let memo = try phone.record("call the plumber")
        try phone.store.delete(id: memo.id)
        #expect(try phone.store.list().isEmpty)
        #expect(try phone.store.blobIDs().isEmpty)
    }

    @Test func exportDescribesAttachmentsLikeTheCLI() throws {
        let phone = try Device(FakeServer())
        let memo = try phone.record("call the plumber")
        try phone.store.add("get milk")
        let notes =
            try JSONSerialization.jsonObject(with: try phone.store.export()) as! [[String: Any]]
        let attachments = try #require(notes[0]["attachments"] as? [[String: Any]])
        #expect(attachments.count == 1)
        #expect(attachments[0]["id"] as? String == memo.attachments[0].id)
        #expect(attachments[0]["kind"] as? String == "audio")
        #expect(attachments[0]["media_type"] as? String == "audio/mp4")
        #expect(attachments[0]["size"] as? Int == recordingBytes.count)
        #expect(attachments[0]["duration_ms"] as? Int == 42_000)
        #expect(notes[1]["attachments"] == nil)
    }

    // MARK: - Sync

    @Test func aSyncSendsTheNoteThenTheRecording() async throws {
        let server = FakeServer()
        let phone = try Device(server)
        let memo = try phone.record("call the plumber")
        let id = memo.attachments[0].id

        #expect(try await phone.syncer.sync() == SyncReport(pushed: 1, pulled: 1, uploaded: 1))
        #expect(server.with { $0.blobs[id] } == recordingBytes)
        #expect(server.with { $0.blobNotes[id] } == memo.id)
        // The note was on the server before its recording.
        let order = server.with { $0.requests.map { "\($0.httpMethod!) \($0.url!.path)" } }
        let push = try #require(order.firstIndex(of: "POST /api/sync/push"))
        let put = try #require(order.firstIndex(of: "PUT /api/blobs/\(id)"))
        #expect(push < put)

        #expect(try await phone.syncer.sync() == SyncReport())
        #expect(server.with { $0.blobPuts } == 1)
    }

    @Test func anotherDeviceGetsTheTextAtOnceAndTheRecordingWhenAsked() async throws {
        let server = FakeServer()
        let phone = try Device(server)
        let memo = try phone.record("call the plumber")
        let id = memo.attachments[0].id
        _ = try await phone.syncer.sync()

        let pad = try Device(server)
        _ = try await pad.syncer.sync()
        #expect(try pad.store.list().map(\.content) == ["call the plumber"])
        #expect(pad.store.localBlob(id) == nil)

        let file = try await pad.syncer.blob(id)
        #expect(try Data(contentsOf: file) == recordingBytes)
        // Kept: the second time needs no server, and it isn't sent back up.
        server.with { $0.offline = true }
        #expect(try await pad.syncer.blob(id) == file)
        server.with { $0.offline = false }
        #expect(try await pad.syncer.sync() == SyncReport())
        #expect(server.with { $0.blobPuts } == 1)
    }

    @Test func aRecordingStillOnItsWaySaysSo() async throws {
        let server = FakeServer()
        let phone = try Device(server)
        let memo = try phone.record("call the plumber")
        server.with { $0.failBlobUploads = true }
        await #expect(throws: (any Error).self) { try await phone.syncer.sync() }

        let pad = try Device(server)
        _ = try await pad.syncer.sync()
        #expect(try pad.store.list().count == 1)
        await #expect(throws: BlobError.notOnServerYet) {
            try await pad.syncer.blob(memo.attachments[0].id)
        }
        // The upload is tried again by the next sync.
        server.with { $0.failBlobUploads = false }
        #expect(try await phone.syncer.sync().uploaded == 1)
        #expect(try Data(contentsOf: try await pad.syncer.blob(memo.attachments[0].id)) == recordingBytes)
    }

    @Test func deletingTheNoteElsewhereDeletesTheRecordingEverywhere() async throws {
        let server = FakeServer()
        let phone = try Device(server)
        let memo = try phone.record("call the plumber")
        let id = memo.attachments[0].id
        _ = try await phone.syncer.sync()
        let pad = try Device(server)
        _ = try await pad.syncer.sync()
        _ = try await pad.syncer.blob(id)

        try pad.store.delete(id: memo.id)
        _ = try await pad.syncer.sync()
        #expect(server.with { $0.blobs[id] } == nil)
        #expect(server.with { $0.deletedBlobs } == [id])

        _ = try await phone.syncer.sync()
        #expect(try phone.store.list().isEmpty)
        #expect(try phone.store.blobIDs().isEmpty)
        #expect(!(try phone.store.loadSyncState().toJson().contains(id)))
    }

    @Test func aRecordingDeletedElsewhereBeforeItWasSentIsNeverSent() async throws {
        let server = FakeServer()
        let phone = try Device(server)
        let memo = try phone.record("call the plumber")
        server.with { $0.failBlobUploads = true }
        await #expect(throws: (any Error).self) { try await phone.syncer.sync() }

        let pad = try Device(server)
        _ = try await pad.syncer.sync()
        try pad.store.delete(id: memo.id)
        _ = try await pad.syncer.sync()

        server.with { $0.failBlobUploads = false }
        #expect(try await phone.syncer.sync().uploaded == 0)
        #expect(server.with { $0.blobs.isEmpty })
        #expect(try phone.store.blobIDs().isEmpty)
    }

    @Test func removingTheRecordingTellsTheServer() async throws {
        let server = FakeServer()
        let phone = try Device(server)
        let memo = try phone.record("call the plumber")
        let id = memo.attachments[0].id
        _ = try await phone.syncer.sync()

        try phone.store.removeAttachment(noteID: memo.id, attachmentID: id)
        _ = try await phone.syncer.sync()
        #expect(server.with { $0.blobs[id] } == nil)
        #expect(try phone.store.list().map(\.content) == ["call the plumber"])
    }

    @Test func anUploadTheServerRefusesAsDeletedIsDropped() async throws {
        // The delete reached the server from elsewhere, but not this phone
        // yet (say its pull page ended early): the refusal isn't an error.
        let server = FakeServer()
        let phone = try Device(server)
        let memo = try phone.record("call the plumber")
        server.with { $0.refusedBlobs = [memo.attachments[0].id] }
        #expect(try await phone.syncer.sync().uploaded == 0)
        #expect(server.with { $0.blobs.isEmpty })
    }

    @Test func aMemoCapturedOutsideTheAppIsSavedThenSynced() async throws {
        let server = FakeServer()
        let phone = try Device(server)
        let capture = Capture(store: phone.store, syncer: phone.syncer)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-\(UUID().uuidString).m4a")
        try recordingBytes.write(to: file)

        let result = try await capture.addMemo(
            recording: file, mediaType: "audio/mp4", durationMs: 42_000, transcript: "call the plumber")
        #expect(result.synced == .synced)
        #expect(server.with { $0.blobs.count } == 1)

        // Offline, it is saved all the same.
        server.with { $0.offline = true }
        try recordingBytes.write(to: file)
        let later = try await capture.addMemo(
            recording: file, mediaType: "audio/mp4", durationMs: 42_000, transcript: nil)
        #expect(later.synced == .later)
        #expect(try phone.store.list().count == 2)
    }
}
