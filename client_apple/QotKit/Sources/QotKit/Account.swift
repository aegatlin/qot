import Foundation

public enum SignInError: Error, Equatable, LocalizedError {
    /// The 15 minutes ran out before the code was typed.
    case expired
    /// The server's reason the sign-in will never succeed (e.g. too many
    /// wrong codes).
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .expired: "The sign-in expired. Start again."
        case .failed(let why): "The sign-in failed: \(why)"
        }
    }
}

/// Which server a session is on, for showing it.
public enum ServerLabel: String, Sendable {
    case production, staging, local, custom

    public static let productionURL = URL(string: "https://api.quantumofthought.com")!

    public static func of(_ url: URL) -> ServerLabel {
        switch url.host() {
        case "api.quantumofthought.com": .production
        case "staging-api.quantumofthought.com": .staging
        case "localhost", "127.0.0.1", "::1": .local
        default: .custom
        }
    }
}

/// The session on this device: the device sign-in (like the CLI's `qot
/// login`), sign-out and account deletion. Credentials go to `credentials`
/// (the Keychain); notes are never touched.
public struct Account: Sendable {
    let store: NoteStore
    let credentials: CredentialStore
    let api: @Sendable (URL) -> ServerAPI

    public init(
        store: NoteStore, credentials: CredentialStore, api: @escaping @Sendable (URL) -> ServerAPI
    ) {
        self.store = store
        self.credentials = credentials
        self.api = api
    }

    public var credentialStore: CredentialStore { credentials }

    public var syncer: Syncer {
        Syncer(store: store, credentials: credentials) { [api] in api($0) }
    }

    public func current() throws -> Credentials? {
        try credentials.load()
    }

    /// Asks the server to email a sign-in link; show `userCode` to the person.
    public func startSignIn(email: String, server: URL) async throws -> DeviceStart {
        try await api(server).startSignIn(email: email)
    }

    /// Polls until the person types the code on the emailed page, then saves
    /// the session. A new session starts sync afresh. `sleep` waits that many
    /// seconds between polls (a no-op in tests).
    @discardableResult
    public func finishSignIn(
        _ start: DeviceStart, server: URL,
        sleep: @Sendable (Int) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async throws -> Credentials {
        let api = api(server)
        var waited = 0
        while true {
            waited += start.interval
            guard waited <= start.expiresIn else { throw SignInError.expired }
            try await sleep(start.interval)
            switch try await api.pollSignIn(deviceCode: start.deviceCode) {
            case .pending:
                continue
            case .failed(let why):
                throw SignInError.failed(why)
            case .approved(let signedIn):
                let creds = Credentials(
                    server: server, userId: signedIn.userId, email: signedIn.email,
                    accessToken: signedIn.accessToken, refreshToken: signedIn.refreshToken)
                try store.forgetSyncState()
                try credentials.save(creds)
                return creds
            }
        }
    }

    /// Revokes the session on the server if it can be reached, then forgets
    /// it and the sync position here either way. Notes stay.
    public func signOut() async throws {
        if let creds = try credentials.load() {
            try? await api(creds.server).signOut(refreshToken: creds.refreshToken)
        }
        try credentials.delete()
        try store.forgetSyncState()
    }

    /// Deletes the account on the server (`confirm` must be its email), then
    /// forgets the session. Notes on this device stay.
    public func deleteAccount(confirm: String) async throws {
        guard var creds = try credentials.load() else { throw SyncError.signedOut }
        let api = api(creds.server)
        do {
            try await api.deleteAccount(token: creds.accessToken, confirm: confirm)
        } catch APIError.unauthorized {
            creds.accessToken = try await api.refresh(refreshToken: creds.refreshToken)
            try credentials.save(creds)
            try await api.deleteAccount(token: creds.accessToken, confirm: confirm)
        }
        try credentials.delete()
        try store.forgetSyncState()
    }
}
