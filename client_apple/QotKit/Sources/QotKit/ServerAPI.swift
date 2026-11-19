import Foundation

/// Sends one HTTP request. `URLSession` in the app; a fake server in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

public enum APIError: Error, Equatable, LocalizedError {
    /// The token was refused: refresh, or sign in again.
    case unauthorized
    /// Too many sign-ins; the server says how many seconds to wait, if it did.
    case rateLimited(retryAfter: Int?)
    /// The server couldn't be reached.
    case offline(String)
    /// The server answered with an error.
    case server(String)
    /// An upload of a blob the server knows was deleted.
    case blobDeleted

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "Not signed in."
        case .offline(let why): return "Can't reach the server: \(why)"
        case .server(let message): return message
        case .blobDeleted: return "That recording was deleted."
        case .rateLimited(let wait):
            let when =
                switch wait.map({ ($0 + 59) / 60 }) {
                case nil: "later"
                case 0, 1: "in a minute"
                case let minutes?: "in \(minutes) minutes"
                }
            return "Too many sign-in attempts. Try again \(when)."
        }
    }
}

/// What starting a device sign-in returns.
public struct DeviceStart: Equatable, Sendable {
    /// Secret; stays on this device and is polled with.
    public let deviceCode: String
    /// `XXXX-XXXX`, shown to the person, who types it on the emailed page.
    public let userCode: String
    public let interval: Int
    public let expiresIn: Int
    /// The PWA, if the server has one.
    public let appURL: URL?

    public init(deviceCode: String, userCode: String, interval: Int, expiresIn: Int, appURL: URL?) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.interval = interval
        self.expiresIn = expiresIn
        self.appURL = appURL
    }
}

public struct SignedIn: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let userId: String
    public let email: String
}

public enum Poll: Equatable, Sendable {
    case pending
    case approved(SignedIn)
    /// Will never succeed (denied, expired, unknown); the server's reason.
    case failed(String)
}

/// One page of the server's change log.
public struct Page: Equatable, Sendable {
    public let changes: [Incoming]
    public let more: Bool
}

/// What sync needs from the server; `ServerAPI` is the real one.
public protocol SyncAPI: Sendable {
    func push(token: String, changes: [Outgoing]) async throws -> UInt64
    func pull(token: String, since: UInt64) async throws -> Page
    func refresh(refreshToken: String) async throws -> String
    /// Uploads an attachment's bytes. Sending the same id again is fine.
    func putBlob(token: String, id: String, noteID: String, data: Data) async throws
    /// An attachment's bytes; nil when the server doesn't have them.
    func getBlob(token: String, id: String) async throws -> Data?
}

/// The HTTP shell around the server API (CLAUDE.md "Server"). No sync
/// decisions here; those are `qot_core::sync`'s.
public struct ServerAPI: SyncAPI {
    public let baseURL: URL
    let transport: HTTPTransport
    let userAgent: String

    public init(baseURL: URL, transport: HTTPTransport, userAgent: String) {
        self.baseURL = baseURL
        self.transport = transport
        self.userAgent = userAgent
    }

    /// `qot-ios/<version> (iOS <version>; <model>)`, so the server can tell
    /// which client versions are still in use.
    public static func userAgent(appVersion: String, osName: String, osVersion: String, model: String)
        -> String
    {
        "qot-ios/\(appVersion) (\(osName) \(osVersion); \(model))"
    }

    // MARK: - Sign-in

    public func startSignIn(email: String) async throws -> DeviceStart {
        let (status, body) = try await call("POST", "/api/auth/device", json: ["email": email])
        switch status {
        case 200:
            guard let deviceCode = body["device_code"] as? String,
                let userCode = body["user_code"] as? String
            else { throw APIError.server("Unexpected reply from server.") }
            return DeviceStart(
                deviceCode: deviceCode, userCode: userCode,
                interval: body["interval"] as? Int ?? 3,
                expiresIn: body["expires_in"] as? Int ?? 900,
                appURL: (body["app_url"] as? String).flatMap(URL.init(string:)))
        case 429: throw APIError.rateLimited(retryAfter: body["retry_after"] as? Int)
        default: throw APIError.server(errorText(body))
        }
    }

    public func pollSignIn(deviceCode: String) async throws -> Poll {
        let (status, body) = try await call(
            "POST", "/api/auth/device/token", json: ["device_code": deviceCode])
        switch status {
        case 200:
            return .approved(try signedIn(body))
        case 400 where body["error"] as? String == "authorization_pending":
            return .pending
        default:
            return .failed(errorText(body))
        }
    }

    /// `POST /api/auth/apple`: Apple's identity token for this app and the
    /// raw nonce (the server checks the token carries its SHA-256), and the
    /// sign-in's authorization code, which the server exchanges for Apple's
    /// refresh token so deleting the account can revoke it.
    public func signInWithApple(identityToken: String, nonce: String, authorizationCode: String?)
        async throws -> SignedIn
    {
        var json = ["identity_token": identityToken, "nonce": nonce]
        json["authorization_code"] = authorizationCode
        let (status, body) = try await call("POST", "/api/auth/apple", json: json)
        switch status {
        case 200: return try signedIn(body)
        case 404: throw SignInError.appleUnsupported
        case 409: throw SignInError.emailInUse
        case 422: throw SignInError.failed("Apple didn't share an email address.")
        case 503: throw SignInError.failed("Apple can't be reached right now. Try again.")
        default: throw SignInError.failed(errorText(body))
        }
    }

    private func signedIn(_ body: [String: Any]) throws -> SignedIn {
        let user = body["user"] as? [String: Any] ?? [:]
        guard let access = body["access_token"] as? String,
            let refresh = body["refresh_token"] as? String,
            let userId = user["id"].map({ "\($0)" }),
            let email = user["email"] as? String
        else { throw APIError.server("Unexpected reply from server.") }
        return SignedIn(accessToken: access, refreshToken: refresh, userId: userId, email: email)
    }

    public func refresh(refreshToken: String) async throws -> String {
        let (status, body) = try await call(
            "POST", "/api/auth/refresh", json: ["refresh_token": refreshToken])
        switch status {
        case 200:
            guard let token = body["access_token"] as? String else {
                throw APIError.server("Unexpected reply from server.")
            }
            return token
        case 401: throw APIError.unauthorized
        default: throw APIError.server(errorText(body))
        }
    }

    /// Revokes the refresh token on the server.
    public func signOut(refreshToken: String) async throws {
        _ = try await call("POST", "/api/auth/logout", json: ["refresh_token": refreshToken])
    }

    /// Deletes the signed-in account. `confirm` must be its email.
    public func deleteAccount(token: String, confirm: String) async throws {
        let (status, body) = try await call(
            "DELETE", "/api/account", token: token, json: ["confirm": confirm])
        switch status {
        case 200: return
        case 401: throw APIError.unauthorized
        default: throw APIError.server(errorText(body))
        }
    }

    // MARK: - Sync

    public func push(token: String, changes: [Outgoing]) async throws -> UInt64 {
        var body: [String: Any] = [
            "changes": changes.map { ["note_id": $0.noteId, "data": $0.data.base64EncodedString()] }
        ]
        // Blobs whose attachment these changes removed, for the server to
        // delete in the same step.
        let deleted = changes.flatMap(\.deletedBlobs)
        if !deleted.isEmpty { body["deleted_blobs"] = deleted }
        let (status, reply) = try await call("POST", "/api/sync/push", token: token, json: body)
        switch status {
        case 200:
            guard let cursor = reply["cursor"] as? Int else {
                throw APIError.server("No cursor in the server's reply.")
            }
            return UInt64(cursor)
        case 401: throw APIError.unauthorized
        default: throw APIError.server(errorText(reply))
        }
    }

    public func pull(token: String, since: UInt64) async throws -> Page {
        let (status, body) = try await call("GET", "/api/sync/pull?since=\(since)", token: token)
        switch status {
        case 200: return try parsePage(body)
        case 401: throw APIError.unauthorized
        default: throw APIError.server(errorText(body))
        }
    }

    // MARK: - Blobs

    public func putBlob(token: String, id: String, noteID: String, data: Data) async throws {
        var request = try self.request("PUT", "/api/blobs/\(id)?note_id=\(noteID)", token: token)
        request.setValue("application/octet-stream", forHTTPHeaderField: "content-type")
        request.httpBody = data
        let (reply, response) = try await send(request)
        switch response.statusCode {
        case 204: return
        case 401: throw APIError.unauthorized
        case 410: throw APIError.blobDeleted
        case 413: throw APIError.server("The recording is too large to sync.")
        case 403: throw APIError.server("Your account's storage is full.")
        default: throw APIError.server(errorText(json(reply)))
        }
    }

    public func getBlob(token: String, id: String) async throws -> Data? {
        let (data, response) = try await send(try request("GET", "/api/blobs/\(id)", token: token))
        switch response.statusCode {
        case 200: return data
        case 404: return nil
        case 401: throw APIError.unauthorized
        default: throw APIError.server(errorText(json(data)))
        }
    }

    // MARK: - HTTP

    private func request(_ method: String, _ path: String, token: String?) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw APIError.server("Bad server address.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "user-agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch let error as URLError {
            throw APIError.offline(error.localizedDescription)
        }
    }

    private func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func call(_ method: String, _ path: String, token: String? = nil, json: [String: Any]? = nil)
        async throws -> (Int, [String: Any])
    {
        var request = try self.request(method, path, token: token)
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await send(request)
        return (response.statusCode, self.json(data))
    }

    private func parsePage(_ body: [String: Any]) throws -> Page {
        guard let changes = body["changes"] as? [[String: Any]] else {
            throw APIError.server("No changes in the server's reply.")
        }
        let incoming = try changes.map { change in
            guard let seq = change["seq"] as? Int,
                let noteId = change["note_id"] as? String,
                let encoded = change["data"] as? String,
                let data = Data(base64Encoded: encoded)
            else { throw APIError.server("A change in the server's reply is malformed.") }
            return Incoming(seq: UInt64(seq), noteId: noteId, data: data)
        }
        return Page(changes: incoming, more: body["more"] as? Bool ?? false)
    }

    private func errorText(_ body: [String: Any]) -> String {
        body["error"] as? String ?? "Unexpected reply from server."
    }
}
