import Foundation

public enum SyncError: Error, Equatable, LocalizedError {
    case signedOut

    public var errorDescription: String? {
        switch self {
        case .signedOut: "Not signed in."
        }
    }
}

/// What a sync moved.
public struct SyncReport: Equatable, Sendable {
    public var pushed = 0
    public var pulled = 0

    public init(pushed: Int = 0, pulled: Int = 0) {
        self.pushed = pushed
        self.pulled = pulled
    }
}

/// Push, then pull, with `qot_core::sync`'s rules (CLAUDE.md "Client sync").
/// The state is saved after every step, so an interrupted sync resumes and
/// anything repeated is harmless. One sync at a time across processes.
public struct Syncer: Sendable {
    /// The most changes one push may carry (the server's limit).
    static let pushChunk = 500

    let store: NoteStore
    let credentials: CredentialStore
    let api: @Sendable (URL) -> SyncAPI

    public init(store: NoteStore, credentials: CredentialStore, api: @escaping @Sendable (URL) -> SyncAPI) {
        self.store = store
        self.credentials = credentials
        self.api = api
    }

    @discardableResult
    public func sync() async throws -> SyncReport {
        try await FileLock.withLock(at: store.directory.appendingPathComponent("sync.lock")) {
            try await syncLocked()
        }
    }

    private func syncLocked() async throws -> SyncReport {
        guard var creds = try credentials.load() else { throw SyncError.signedOut }
        let api = api(creds.server)
        var report = SyncReport()
        var state = try store.loadSyncState()

        let outgoing = planPush(notes: try store.allNotes(), state: state)
        for start in stride(from: 0, to: outgoing.count, by: Self.pushChunk) {
            let chunk = Array(outgoing[start..<min(start + Self.pushChunk, outgoing.count)])
            _ = try await authed(api, &creds) { try await api.push(token: $0, changes: chunk) }
            state = markPushed(state: state, sent: chunk)
            try store.saveSyncState(state)
            report.pushed += chunk.count
        }

        while true {
            let since = state.cursor()
            let page = try await authed(api, &creds) { try await api.pull(token: $0, since: since) }
            let pulled = try wrap {
                try applyPulled(notes: try store.allNotes(), state: state, incoming: page.changes)
            }
            try store.merge(pulled.changed)
            state = pulled.state
            try store.saveSyncState(state)
            report.pulled += page.changes.count
            if !page.more { break }
        }
        return report
    }

    /// Runs `call` with the access token, refreshing it once if refused.
    private func authed<T>(
        _ api: SyncAPI, _ creds: inout Credentials, _ call: (String) async throws -> T
    ) async throws -> T {
        do {
            return try await call(creds.accessToken)
        } catch APIError.unauthorized {
            creds.accessToken = try await api.refresh(refreshToken: creds.refreshToken)
            try credentials.save(creds)
            return try await call(creds.accessToken)
        }
    }
}
