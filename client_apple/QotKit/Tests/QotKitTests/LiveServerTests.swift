import Foundation
import Synchronization
import Testing

@testable import QotKit

/// Against a real dev server, over real HTTP and WebSocket. Skipped unless
/// `QOT_E2E_SERVER` (e.g. `http://localhost:4000`) and `QOT_E2E_SERVER_LOG`
/// (the server's log, where dev prints sign-in emails) are set; see
/// CLAUDE.md "Apple". Signs in `QOT_E2E_EMAIL` (default `e2e@example.com`)
/// on two QotKit devices, then checks a note moves between them, live.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["QOT_E2E_SERVER"] != nil))
struct LiveServerTests {
    let env = ProcessInfo.processInfo.environment
    var server: URL { URL(string: env["QOT_E2E_SERVER"]!)! }
    var email: String { env["QOT_E2E_EMAIL"] ?? "e2e@example.com" }

    func device() throws -> Account {
        Account(store: try NoteStore(directory: tempDir()), credentials: MemoryCredentialStore()) {
            ServerAPI(baseURL: $0, transport: URLSession.shared, userAgent: "qot-ios/e2e (test)")
        }
    }

    /// Signs in the way a person would: start, read the emailed link from the
    /// dev log, type the code on it.
    func signIn(_ account: Account) async throws {
        let start = try await account.startSignIn(email: email, server: server)
        try await Task.sleep(for: .milliseconds(300))  // the log is written async
        let log = try String(contentsOfFile: env["QOT_E2E_SERVER_LOG"]!, encoding: .utf8)
        let token = try #require(
            log.matches(of: /auth\/device\?token=([A-Za-z0-9_%-]+)/).last.map { String($0.1) })
        var request = URLRequest(url: server.appending(path: "/api/auth/device/approve"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "token": token, "user_code": start.userCode, "sign_in_browser": false,
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        try await account.finishSignIn(start, server: server)
    }

    @Test(.timeLimit(.minutes(1))) func notesMoveBetweenDevicesLive() async throws {
        let phone = try device()
        let laptop = try device()
        try await signIn(phone)
        try await signIn(laptop)
        try await phone.syncer.sync()
        try await laptop.syncer.sync()

        let nudged = Mutex(0)
        let live = LiveNudges(credentials: laptop.credentialStore) {
            nudged.withLock { $0 += 1 }
        }
        defer { live.stop() }
        try await Task.sleep(for: .seconds(1))  // let it join

        let text = "from QotKit \(UUID().uuidString.prefix(8))"
        try phone.store.add(text)
        try await phone.syncer.sync()

        for _ in 0..<50 where nudged.withLock({ $0 }) == 0 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(nudged.withLock { $0 } > 0, "the laptop was nudged")
        try await laptop.syncer.sync()
        #expect(try laptop.store.list().contains { $0.content == text })
    }
}
