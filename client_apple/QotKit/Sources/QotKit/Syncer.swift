import Foundation

public enum SyncError: Error, Equatable, LocalizedError {
    case signedOut

    public var errorDescription: String? {
        switch self {
        case .signedOut: "Not signed in."
        }
    }
}

public enum BlobError: Error, Equatable, LocalizedError {
    /// The server doesn't have the bytes: the device that recorded them
    /// hasn't sent them yet (or they were deleted, and the note will follow).
    case notOnServerYet

    public var errorDescription: String? {
        switch self {
        case .notOnServerYet:
            "Audio on its way. It plays here once the device that recorded it has sent it."
        }
    }
}

/// What a sync moved.
public struct SyncReport: Equatable, Sendable {
    public var pushed = 0
    public var pulled = 0
    /// Attachments' bytes sent to the server.
    public var uploaded = 0

    public init(pushed: Int = 0, pulled: Int = 0, uploaded: Int = 0) {
        self.pushed = pushed
        self.pulled = pulled
        self.uploaded = uploaded
    }
}

/// Push, then pull, then attachments' bytes, with `qot_core::sync`'s rules
/// (CLAUDE.md "Client sync"). The state is saved after every step, so an
/// interrupted sync resumes and anything repeated is harmless. One sync at a
/// time across processes.
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

        // Blobs last: the note is on the server before its recording, and a
        // delete pulled just now stops an upload nothing would point to.
        let plan = try store.locked {
            let plan = planBlobs(
                notes: try store.allNotes(), state: state, local: try store.blobIDs())
            try store.removeBlobs(plan.discard)
            return plan
        }
        if !plan.discard.isEmpty {
            state = forgetBlobs(state: state, ids: plan.discard)
            try store.saveSyncState(state)
        }
        for upload in plan.upload {
            guard let file = store.localBlob(upload.id) else { continue }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            do {
                try await authed(api, &creds) {
                    try await api.putBlob(token: $0, id: upload.id, noteID: upload.noteId, data: data)
                }
            } catch APIError.blobDeleted {
                // Deleted on another device; the note's delete follows in a
                // pull, and the file goes then.
                continue
            }
            state = markUploaded(state: state, ids: [upload.id])
            try store.saveSyncState(state)
            report.uploaded += 1
        }
        return report
    }

    /// An attachment's bytes as a file: from this device if it has them,
    /// else fetched from the server and kept. Throws `BlobError
    /// .notOnServerYet` while the device that recorded it hasn't sent it.
    public func blob(_ id: String) async throws -> URL {
        if let local = store.localBlob(id) { return local }
        guard var creds = try credentials.load() else { throw SyncError.signedOut }
        let api = api(creds.server)
        guard let data = try await authed(api, &creds, { try await api.getBlob(token: $0, id: id) })
        else { throw BlobError.notOnServerYet }
        // The sync state is a sync's to write, so this waits for one running.
        return try FileLock.withLock(at: store.directory.appendingPathComponent("sync.lock")) {
            let file = try store.saveBlob(id, data)
            try store.saveSyncState(markUploaded(state: try store.loadSyncState(), ids: [id]))
            return file
        }
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
