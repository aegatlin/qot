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
}

@Suite struct SyncTests {
    @Test func aNoteOnOneDeviceReachesAnother() async throws {
        let server = FakeServer()
        let phone = try Device(server)
        let laptop = try Device(server)

        try phone.store.add("get milk")
        #expect(try await phone.syncer.sync() == SyncReport(pushed: 1, pulled: 1))
        #expect(try await laptop.syncer.sync() == SyncReport(pushed: 0, pulled: 1))
        #expect(try laptop.store.list().map(\.content) == ["get milk"])
    }

    @Test func deletesSync() async throws {
        let server = FakeServer()
        let phone = try Device(server)
        let laptop = try Device(server)
        let note = try phone.store.add("get milk")
        _ = try await phone.syncer.sync()
        _ = try await laptop.syncer.sync()

        try laptop.store.delete(id: note.id)
        _ = try await laptop.syncer.sync()
        _ = try await phone.syncer.sync()
        #expect(try phone.store.list().isEmpty)
    }

    @Test func aSecondSyncMovesNothing() async throws {
        let server = FakeServer()
        let phone = try Device(server)
        try phone.store.add("get milk")
        _ = try await phone.syncer.sync()
        #expect(try await phone.syncer.sync() == SyncReport(pushed: 0, pulled: 0))
        #expect(try phone.store.unsyncedCount() == 0)
    }

    @Test func pullsEveryPage() async throws {
        let server = FakeServer()
        server.with { $0.pageSize = 2 }
        let phone = try Device(server)
        let laptop = try Device(server)
        for i in 1...5 { try phone.store.add("note \(i)") }
        _ = try await phone.syncer.sync()
        #expect(try await laptop.syncer.sync().pulled == 5)
        #expect(try laptop.store.list().count == 5)
    }

    @Test func pushesInChunksTheServerAccepts() async throws {
        let server = FakeServer()
        let phone = try Device(server)
        for i in 1...(Syncer.pushChunk + 1) { try phone.store.add("note \(i)") }
        _ = try await phone.syncer.sync()
        #expect(server.with { $0.pushes } == 2)
    }

    @Test func anExpiredTokenIsRefreshedAndSaved() async throws {
        let server = FakeServer()
        let phone = try Device(server)
        server.with { $0.validAccess = [] }
        try phone.store.add("get milk")
        _ = try await phone.syncer.sync()
        #expect(server.with { $0.refreshes } == 1)
        #expect(try phone.credentials.load()?.accessToken == "access-2")
    }

    @Test func aRevokedSessionIsNotSignedIn() async throws {
        let server = FakeServer()
        let phone = try Device(server)
        server.with {
            $0.validAccess = []
            $0.validRefresh = []
        }
        await #expect(throws: APIError.unauthorized) { try await phone.syncer.sync() }
    }

    @Test func signedOutSyncIsAnError() async throws {
        let phone = try Device(FakeServer(), signedIn: nil)
        await #expect(throws: SyncError.signedOut) { try await phone.syncer.sync() }
    }

    @Test func offlineKeepsTheNoteForNextTime() async throws {
        let server = FakeServer()
        let phone = try Device(server)
        server.with { $0.offline = true }
        try phone.store.add("get milk")
        await #expect(throws: APIError.self) { try await phone.syncer.sync() }
        #expect(try phone.store.unsyncedCount() == 1)

        server.with { $0.offline = false }
        #expect(try await phone.syncer.sync().pushed == 1)
    }

    @Test func pushProgressIsSavedEvenIfThePullFails() async throws {
        let server = FakeServer()
        let phone = try Device(server)
        try phone.store.add("get milk")
        // The push succeeds; every pull is refused and can't be refreshed.
        let syncer = Syncer(store: phone.store, credentials: phone.credentials) { base in
            PullFails(inner: ServerAPI(baseURL: base, transport: server, userAgent: "t"))
        }
        await #expect(throws: APIError.self) { try await syncer.sync() }
        #expect(try phone.store.unsyncedCount() == 0)
    }

    @Test func concurrentSyncsDontRepeatWork() async throws {
        let server = FakeServer()
        let phone = try Device(server)
        try phone.store.add("get milk")
        async let a = phone.syncer.sync()
        async let b = phone.syncer.sync()
        let reports = try await [a, b]
        #expect(reports.map(\.pushed).reduce(0, +) == 1)
        #expect(server.with { $0.log.count } == 1)
    }
}

/// A client whose pulls always fail, to show the push step was saved.
private struct PullFails: SyncAPI {
    let inner: ServerAPI
    func push(token: String, changes: [Outgoing]) async throws -> UInt64 {
        try await inner.push(token: token, changes: changes)
    }
    func pull(token: String, since: UInt64) async throws -> Page {
        throw APIError.server("pull refused")
    }
    func refresh(refreshToken: String) async throws -> String {
        try await inner.refresh(refreshToken: refreshToken)
    }
}
