import Foundation
import Testing

@testable import QotKit

private struct Phone {
    let store: NoteStore
    let capture: Capture
    let syncer: Syncer

    init(_ server: FakeServer, signedIn creds: Credentials? = signedIn()) throws {
        store = try NoteStore(directory: tempDir())
        syncer = Syncer(store: store, credentials: MemoryCredentialStore(creds)) { base in
            ServerAPI(baseURL: base, transport: server, userAgent: "qot-ios/test")
        }
        capture = Capture(store: store, syncer: syncer)
    }

    /// A finished recording where the recorder writes them.
    func recording(_ bytes: Data = audio) throws -> URL {
        let file = try store.newRecordingURL()
        try bytes.write(to: file)
        return file
    }

    func finish(_ transcribe: @escaping Capture.Transcribe) async throws -> Capture.MemoResult {
        try await capture.finishMemo(
            recording: try recording(), mediaType: "audio/mp4", durationMs: 42_000,
            transcribe: transcribe)
    }
}

private let audio = Data([9, 8, 7, 6])
private struct NoModelYet: Error {}

@Suite struct MemoFlowTests {
    @Test func aFinishedRecordingBecomesASyncedNoteWithItsAudioAndItsText() async throws {
        let server = FakeServer()
        let phone = try Phone(server)

        let result = try await phone.finish { file in
            // The transcriber is handed the recording where the store keeps it.
            let heard = try Data(contentsOf: file)
            #expect(heard == audio)
            return "call the plumber"
        }

        #expect(result.note.content == "call the plumber")
        #expect(result.transcribed)
        #expect(result.synced == .synced)
        let id = try #require(result.note.attachments.first?.id)
        #expect(server.with { $0.blobs[id] } == audio)
        // Another device gets the text.
        let laptop = try Phone(server)
        try await laptop.syncer.sync()
        #expect(try laptop.store.list().map(\.content) == ["call the plumber"])
        #expect(try phone.store.strandedRecordings().isEmpty)
    }

    @Test func theAudioIsOnTheServerBeforeTranscriptionStarts() async throws {
        let server = FakeServer()
        let phone = try Phone(server)
        _ = try await phone.finish { _ in
            #expect(server.with { $0.blobs.count } == 1)
            return "later text"
        }
    }

    @Test func aFailedTranscriptionKeepsTheMemoAndWaits() async throws {
        let server = FakeServer()
        let phone = try Phone(server)

        let result = try await phone.finish { _ in throw NoModelYet() }

        #expect(!result.transcribed)
        #expect(result.note.attachments.first?.text == .pending)
        #expect(server.with { $0.blobs.count } == 1)
        #expect(try phone.store.pendingTranscripts().count == 1)

        // Later (the next launch) it is tried again, and synced.
        let filled = await phone.capture.transcribePending { _ in "second try" }
        #expect(filled == 1)
        #expect(try phone.store.list().map(\.content) == ["second try"])
        #expect(try phone.store.pendingTranscripts().isEmpty)
        let laptop = try Phone(server)
        try await laptop.syncer.sync()
        #expect(try laptop.store.list().map(\.content) == ["second try"])
    }

    @Test func aRecordingThisDeviceCannotTranscribeIsNotAskedAgain() async throws {
        let phone = try Phone(FakeServer())
        let result = try await phone.finish { _ in nil }
        #expect(result.note.content == "")
        #expect(result.note.attachments.first?.text == .done)
        #expect(await phone.capture.transcribePending { _ in "never" } == 0)
    }

    @Test func signedOutTheMemoIsStillSavedAndTranscribed() async throws {
        let phone = try Phone(FakeServer(), signedIn: nil)
        let result = try await phone.finish { _ in "note to self" }
        #expect(result.synced == .signedOut)
        #expect(try phone.store.list().map(\.content) == ["note to self"])
    }

    @Test func aMemoRecordedElsewhereIsNotTranscribedHere() async throws {
        let server = FakeServer()
        let phone = try Phone(server)
        _ = try await phone.finish { _ in throw NoModelYet() }
        let other = try Phone(server)
        try await other.syncer.sync()
        // The other device has the note but not the file: not its job.
        #expect(await other.capture.transcribePending { _ in "wrong device" } == 0)
        #expect(try other.store.list().map(\.content) == [""])
    }

    // MARK: - Where a recording in progress lives

    @Test func aRecordingInProgressIsOutsideTheBlobsASyncLooksAt() throws {
        let phone = try Phone(FakeServer())
        let file = try phone.recording()
        #expect(file.pathExtension == "m4a")
        #expect(file.deletingLastPathComponent().lastPathComponent == "recordings")
        #expect(try phone.store.blobIDs().isEmpty)
        // Left behind by a recording that was cut off: found on launch.
        #expect(try phone.store.strandedRecordings().map(\.lastPathComponent) == [file.lastPathComponent])
    }
}
