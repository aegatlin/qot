import Foundation
import Testing

@testable import QotKit

/// A transport that never answers in time: a server down a slow network.
private struct Hangs: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await Task.sleep(for: .seconds(30))
        throw URLError(.timedOut)
    }
}

private func capture(_ transport: HTTPTransport, signedIn creds: Credentials? = signedIn()) throws
    -> (Capture, NoteStore)
{
    let store = try NoteStore(directory: tempDir())
    let syncer = Syncer(store: store, credentials: MemoryCredentialStore(creds)) { base in
        ServerAPI(baseURL: base, transport: transport, userAgent: "qot-ios/test")
    }
    return (Capture(store: store, syncer: syncer), store)
}

@Suite struct CaptureTests {
    @Test func savesThenSyncs() async throws {
        let server = FakeServer()
        let (capture, store) = try capture(server)
        let result = try await capture.add("get milk")
        #expect(result.note.content == "get milk")
        #expect(result.synced == .synced)
        #expect(try store.list().map(\.content) == ["get milk"])
        #expect(server.with { $0.log.count } == 1)
    }

    @Test func aSlowServerDoesntHoldUpCapture() async throws {
        let (capture, store) = try capture(Hangs())
        let started = ContinuousClock.now
        let result = try await capture.add("get milk", syncFor: .milliseconds(200))
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(result.synced == .later)
        #expect(try store.list().count == 1)  // saved regardless
    }

    @Test func offlineIsSavedForLater() async throws {
        let server = FakeServer()
        server.with { $0.offline = true }
        let (capture, store) = try capture(server)
        let result = try await capture.add("get milk")
        #expect(result.synced == .later)
        #expect(try store.unsyncedCount() == 1)
    }

    @Test func signedOutSavesLocally() async throws {
        let (capture, store) = try capture(FakeServer(), signedIn: nil)
        let result = try await capture.add("get milk")
        #expect(result.synced == .signedOut)
        #expect(try store.list().count == 1)
    }

    @Test func blankIsAnError() async throws {
        let (capture, _) = try capture(FakeServer())
        await #expect(throws: NoteStoreError.blank) { try await capture.add("  ") }
    }

    @Test func latestNotesAreNewestFirst() throws {
        let store = try NoteStore(directory: tempDir())
        for i in 1...5 { try store.add("note \(i)") }
        #expect(try store.latest(3).map(\.content) == ["note 5", "note 4", "note 3"])
    }
}
