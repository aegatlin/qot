import Foundation
import Testing

@testable import QotKit

private let base = URL(string: "https://api.example.com")!

private func account(_ server: FakeServer, signedIn creds: Credentials? = nil) throws -> (
    Account, MemoryCredentialStore, NoteStore
) {
    let store = try NoteStore(directory: tempDir())
    let credentials = MemoryCredentialStore(creds)
    let account = Account(store: store, credentials: credentials) { base in
        ServerAPI(baseURL: base, transport: server, userAgent: "qot-ios/test")
    }
    return (account, credentials, store)
}

@Suite struct SignInTests {
    @Test func signingInWaitsForApprovalThenSavesCredentials() async throws {
        let server = FakeServer()
        let (account, credentials, _) = try account(server)
        let start = try await account.startSignIn(email: "me@example.com", server: base)
        #expect(start.userCode == "ABCD-EFGH")

        // Approve on the third poll.
        let creds = try await account.finishSignIn(start, server: base) { _ in
            if server.with({ $0.polls }) >= 2 { server.with { $0.approved = true } }
        }
        #expect(creds == signedIn(base))
        #expect(try credentials.load() == creds)
        #expect(server.with { $0.polls } == 3)
    }

    @Test func signingInWithAppleSavesCredentials() async throws {
        let server = FakeServer()
        let (account, credentials, _) = try account(server)
        let creds = try await account.signInWithApple(
            identityToken: "apple-token", nonce: "nonce-1", server: base)
        #expect(creds == signedIn(base))
        #expect(try credentials.load() == creds)
        let sent = try #require(server.with { $0.requests.last?.httpBody })
        let json = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: String])
        #expect(json == ["identity_token": "apple-token", "nonce": "nonce-1"])
    }

    @Test func aRejectedAppleSignInSavesNothing() async throws {
        let server = FakeServer()
        let (account, credentials, _) = try account(server)
        await #expect(throws: SignInError.self) {
            try await account.signInWithApple(identityToken: "forged", nonce: "n", server: base)
        }
        #expect(try credentials.load() == nil)
    }

    @Test func anAppleSignInOnATakenEmailSaysWhy() async throws {
        let server = FakeServer()
        let (account, _, _) = try account(server)
        do {
            try await account.signInWithApple(identityToken: "taken-email", nonce: "n", server: base)
            Issue.record("expected an error")
        } catch let error as SignInError {
            #expect(error.localizedDescription.contains("email"))
        }
    }

    @Test func aServerWithoutSignInWithAppleSaysSo() async throws {
        // A server deployed before /api/auth/apple answers 404.
        let server = FakeServer()
        let (account, _, _) = try account(server)
        await #expect(throws: SignInError.appleUnsupported) {
            try await account.signInWithApple(identityToken: "old-server", nonce: "n", server: base)
        }
    }

    @Test func aSignInThatFailsStopsPolling() async throws {
        let server = FakeServer()
        let (account, credentials, _) = try account(server)
        let start = DeviceStart(
            deviceCode: "nope", userCode: "X", interval: 1, expiresIn: 900, appURL: nil)
        await #expect(throws: SignInError.failed("invalid_device_code")) {
            try await account.finishSignIn(start, server: base) { _ in }
        }
        #expect(try credentials.load() == nil)
    }

    @Test func aSignInExpires() async throws {
        let server = FakeServer()
        let (account, _, _) = try account(server)
        let start = DeviceStart(
            deviceCode: "device-1", userCode: "X", interval: 5, expiresIn: 12, appURL: nil)
        await #expect(throws: SignInError.expired) {
            try await account.finishSignIn(start, server: base) { _ in }
        }
        #expect(server.with { $0.polls } == 2)  // at 5 s and 10 s
    }

    @Test func signingOutRevokesAndForgetsButKeepsNotes() async throws {
        let server = FakeServer()
        let (account, credentials, store) = try account(server, signedIn: signedIn())
        try store.add("get milk")
        try store.saveSyncState(.empty())

        try await account.signOut()
        #expect(try credentials.load() == nil)
        #expect(server.with { $0.validRefresh.isEmpty })
        #expect(try store.list().count == 1)
        #expect(try store.loadSyncState().cursor() == 0)
    }

    @Test func signingOutOfflineStillForgetsTheSession() async throws {
        let server = FakeServer()
        server.with { $0.offline = true }
        let (account, credentials, _) = try account(server, signedIn: signedIn())
        try await account.signOut()
        #expect(try credentials.load() == nil)
    }

    @Test func deletingTheAccountNeedsTheEmailAndKeepsNotes() async throws {
        let server = FakeServer()
        let (account, credentials, store) = try account(server, signedIn: signedIn())
        try store.add("get milk")

        await #expect(throws: APIError.self) { try await account.deleteAccount(confirm: "nope") }
        #expect(try credentials.load() != nil)

        try await account.deleteAccount(confirm: "me@example.com")
        #expect(try credentials.load() == nil)
        #expect(try store.list().count == 1)
    }

    @Test func serverLabels() {
        #expect(ServerLabel.of(URL(string: "https://api.quantumofthought.com")!) == .production)
        #expect(ServerLabel.of(URL(string: "https://staging-api.quantumofthought.com")!) == .staging)
        #expect(ServerLabel.of(URL(string: "http://localhost:4000")!) == .local)
        #expect(ServerLabel.of(URL(string: "http://127.0.0.1:4000")!) == .local)
        #expect(ServerLabel.of(URL(string: "https://example.com")!) == .custom)
    }
}

@Suite struct LiveTests {
    @Test func theSocketURLCarriesTheTokenAndProtocolVersion() {
        #expect(
            LiveNudges.socketURL(server: URL(string: "https://api.example.com")!, token: "a b")
                == URL(string: "wss://api.example.com/socket/websocket?token=a%20b&vsn=2.0.0"))
        #expect(
            LiveNudges.socketURL(server: URL(string: "http://localhost:4000")!, token: "t")
                == URL(string: "ws://localhost:4000/socket/websocket?token=t&vsn=2.0.0"))
    }

    @Test func joinAndHeartbeatFrames() throws {
        #expect(PhoenixFrame.join(topic: "notes:user:42", ref: "1").text
            == #"["1","1","notes:user:42","phx_join",{}]"#)
        #expect(PhoenixFrame.heartbeat(ref: "2").text == #"[null,"2","phoenix","heartbeat",{}]"#)
    }

    @Test func recognisesTheChangedNudge() {
        #expect(PhoenixFrame.isNudge(#"[null,null,"notes:user:42","changed",{"cursor":7}]"#, topic: "notes:user:42"))
        #expect(!PhoenixFrame.isNudge(#"[null,null,"notes:user:9","changed",{}]"#, topic: "notes:user:42"))
        #expect(!PhoenixFrame.isNudge(#"["1","1","notes:user:42","phx_reply",{"status":"ok"}]"#, topic: "notes:user:42"))
        #expect(!PhoenixFrame.isNudge("garbage", topic: "notes:user:42"))
    }

    @Test func aRefusedJoinIsRecognised() {
        #expect(PhoenixFrame.joinRefused(#"["1","1","notes:user:42","phx_reply",{"status":"error","response":{}}]"#))
        #expect(!PhoenixFrame.joinRefused(#"["1","1","notes:user:42","phx_reply",{"status":"ok","response":{}}]"#))
    }
}

@Suite struct ExportTests {
    @Test func exportIsTheCLIsJSON() throws {
        let store = try NoteStore(directory: tempDir())
        let a = try store.add("get milk")
        let b = try store.add("call mom")
        try store.delete(id: b.id)

        let data = try store.export()
        let notes = try JSONSerialization.jsonObject(with: data) as? [[String: String]]
        let note = try #require(notes?.first)
        #expect(notes?.count == 1)
        #expect(note["id"] == a.id)
        #expect(note["content"] == "get milk")
        #expect(note["created_at"] == Export.timestamp(a.createdAt))
    }

    @Test func timestampsAreUTCToTheSecond() {
        #expect(Export.timestamp(Date(timeIntervalSince1970: 0.9)) == "1970-01-01T00:00:00Z")
        #expect(Export.timestamp(Date(timeIntervalSince1970: 1_793_770_899)) == "2026-11-04T05:41:39Z")
    }
}
