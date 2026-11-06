import Foundation
import Synchronization

@testable import QotKit

/// An in-memory stand-in for the sync server's HTTP API: one user's
/// append-only log with gap-free seqs, tokens that can expire, and a device
/// sign-in that can be approved. The Swift twin of the PWA's
/// `tests/fake-server.ts`.
final class FakeServer: HTTPTransport, Sendable {
    struct Entry: Sendable {
        let seq: Int
        let noteId: String
        let data: String
    }

    struct State: Sendable {
        var log: [Entry] = []
        var validAccess: Set<String> = ["access-1"]
        var validRefresh: Set<String> = ["refresh-1"]
        var offline = false
        var pageSize = 500
        var refreshes = 0
        var issued = 1
        var pushes = 0
        var approved = false
        var polls = 0
        var deletedWith: String?
        var requests: [URLRequest] = []
        var rateLimitedFor: Int?
    }

    let state = Mutex(State())

    func with<T>(_ body: (inout State) -> T) -> T {
        state.withLock { body(&$0) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, json) = try state.withLock { s -> (Int, Any) in
            s.requests.append(request)
            if s.offline { throw URLError(.notConnectedToInternet) }
            return handle(request, &s)
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["content-type": "application/json"])!
        return (data, response)
    }

    private func handle(_ request: URLRequest, _ s: inout State) -> (Int, Any) {
        let url = request.url!
        let body =
            request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            as? [String: Any] ?? [:]
        let auth = request.value(forHTTPHeaderField: "authorization")?
            .replacingOccurrences(of: "Bearer ", with: "")
        let authorized = auth.map { s.validAccess.contains($0) } ?? false

        switch "\(request.httpMethod ?? "GET") \(url.path)" {
        case "POST /api/auth/device":
            if let wait = s.rateLimitedFor {
                return (429, ["error": "rate_limited", "retry_after": wait])
            }
            return (
                200,
                [
                    "device_code": "device-1", "user_code": "ABCD-EFGH", "interval": 3,
                    "expires_in": 900, "app_url": "https://app.example.com",
                ]
            )
        case "POST /api/auth/device/token":
            s.polls += 1
            guard body["device_code"] as? String == "device-1" else {
                return (400, ["error": "invalid_device_code"])
            }
            guard s.approved else { return (400, ["error": "authorization_pending"]) }
            return (
                200,
                [
                    "access_token": "access-1", "refresh_token": "refresh-1",
                    "user": ["id": 42, "email": "me@example.com"],
                ]
            )
        case "POST /api/auth/refresh":
            guard let token = body["refresh_token"] as? String, s.validRefresh.contains(token)
            else { return (401, ["error": "Invalid or expired refresh token"]) }
            s.refreshes += 1
            s.issued += 1
            s.validAccess.insert("access-\(s.issued)")
            return (200, ["access_token": "access-\(s.issued)"])
        case "POST /api/auth/logout":
            if let token = body["refresh_token"] as? String { s.validRefresh.remove(token) }
            return (200, ["message": "Logged out successfully"])
        case "POST /api/sync/push":
            guard authorized else { return (401, ["error": "unauthorized"]) }
            s.pushes += 1
            for change in body["changes"] as? [[String: Any]] ?? [] {
                s.log.append(
                    Entry(
                        seq: s.log.count + 1, noteId: change["note_id"] as! String,
                        data: change["data"] as! String))
            }
            return (200, ["cursor": s.log.count])
        case "GET /api/sync/pull":
            guard authorized else { return (401, ["error": "unauthorized"]) }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let since = Int(query.first { $0.name == "since" }?.value ?? "0") ?? 0
            let page = s.log.filter { $0.seq > since }.prefix(s.pageSize)
            let cursor = page.last?.seq ?? since
            return (
                200,
                [
                    "changes": page.map { ["seq": $0.seq, "note_id": $0.noteId, "data": $0.data] },
                    "cursor": cursor, "more": cursor < s.log.count,
                ]
            )
        case "DELETE /api/account":
            guard authorized else { return (401, ["error": "unauthorized"]) }
            guard body["confirm"] as? String == "me@example.com" else {
                return (422, ["error": "Type your email to confirm"])
            }
            s.deletedWith = body["confirm"] as? String
            return (200, ["deleted": true])
        default:
            return (404, ["error": "not found"])
        }
    }
}

/// A temporary directory per test; never a real store.
func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("qotkit-\(UUID().uuidString)")
}

func signedIn(_ server: URL = URL(string: "https://api.example.com")!) -> Credentials {
    Credentials(
        server: server, userId: "42", email: "me@example.com",
        accessToken: "access-1", refreshToken: "refresh-1")
}
