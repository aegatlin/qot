import Foundation
import Observation
import QotKit
import WidgetKit

/// The app's state over QotKit. Every action saves locally first and then
/// syncs in the background: capture never waits on the network. Errors from
/// actions are shown; sync problems are shown quietly and retried.
@MainActor @Observable
final class AppModel {
    private let store: NoteStore?
    private let account: Account?
    private(set) var notes: [NoteItem] = []
    private(set) var session: Credentials?
    private(set) var unsynced = 0
    private(set) var syncing = false
    /// Why the last sync failed (offline, signed out elsewhere), if it did.
    private(set) var syncProblem: String?
    var error: String?

    private var syncAgain = false
    private var live: LiveNudges?

    init(store: NoteStore?, credentials: CredentialStore, error: String? = nil) {
        self.store = store
        self.error = error
        account = store.map { store in
            Account(store: store, credentials: credentials) { base in
                ServerAPI(baseURL: base, transport: AppModel.session, userAgent: UserAgent.value)
            }
        }
        session = try? account?.current()
        reload()
        NotificationCenter.default.addObserver(
            forName: NotesChanged.name, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// The shared App Group store and the Keychain session.
    static func onDevice() -> AppModel {
        do {
            return AppModel(store: try AppGroup.store(), credentials: AppGroup.credentials())
        } catch {
            return AppModel(
                store: nil, credentials: MemoryCredentialStore(), error: error.localizedDescription)
        }
    }

    // MARK: - Notes

    /// Saves a new note and returns it (nil if it couldn't be saved).
    func create(_ content: String) -> NoteItem? {
        var created: NoteItem?
        if perform({ created = try $0.add(content) }) { syncSoon() }
        return created
    }

    /// Saves an edit. The editor calls this as you type, so the sync waits
    /// for a pause in typing.
    @discardableResult
    func update(id: String, content: String) -> NoteItem? {
        var edited: NoteItem?
        if perform({ edited = try $0.update(id: id, content: content) }) { syncSoon() }
        return edited
    }

    func delete(id: String) {
        if perform({ try $0.delete(id: id) }) { syncInBackground() }
    }

    func note(id: String) -> NoteItem? {
        notes.first { $0.id == id }
    }

    func reload() {
        perform { _ in }
    }

    func export() -> Data? {
        guard let store else { return nil }
        do {
            return try store.export()
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    private func perform(_ action: (NoteStore) throws -> Void) -> Bool {
        guard let store else { return false }
        do {
            try action(store)
            let next = Array(try store.list().reversed())
            if next != notes { WidgetCenter.shared.reloadAllTimelines() }
            notes = next
            unsynced = try store.unsyncedCount()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - Sync

    func syncInBackground() {
        pendingSync?.cancel()
        Task { await sync() }
    }

    private var pendingSync: Task<Void, Never>?

    /// Syncs once typing pauses for a moment, not on every saved keystroke.
    func syncSoon() {
        pendingSync?.cancel()
        pendingSync = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    /// Syncs if signed in. A request while one runs runs once more after it,
    /// so a nudge mid-sync isn't lost.
    func sync() async {
        guard let account, session != nil else { return }
        if syncing {
            syncAgain = true
            return
        }
        syncing = true
        defer { syncing = false }
        repeat {
            syncAgain = false
            do {
                try await account.syncer.sync()
                syncProblem = nil
            } catch {
                syncProblem = error.localizedDescription
            }
            session = try? account.current()
            reload()
        } while syncAgain
    }

    /// While the app is in front: sync, and listen for the server's nudges.
    func becameActive() {
        syncInBackground()
        guard live == nil, session != nil, let credentials = account?.credentialStore else { return }
        live = LiveNudges(credentials: credentials) { [weak self] in
            await self?.sync()
        }
    }

    func becameInactive() {
        live?.stop()
        live = nil
    }

    // MARK: - Session

    func startSignIn(email: String, server: URL) async throws -> DeviceStart {
        guard let account else { throw SyncError.signedOut }
        return try await account.startSignIn(email: email, server: server)
    }

    func finishSignIn(_ start: DeviceStart, server: URL) async throws {
        guard let account else { return }
        session = try await account.finishSignIn(start, server: server)
        becameInactive()
        becameActive()
    }

    func signOut() async {
        becameInactive()
        do {
            try await account?.signOut()
        } catch {
            self.error = error.localizedDescription
        }
        session = try? account?.current()
        syncProblem = nil
        reload()
    }

    func deleteAccount(confirm: String) async throws {
        try await account?.deleteAccount(confirm: confirm)
        becameInactive()
        session = nil
        syncProblem = nil
        reload()
    }

    // MARK: - Network

    nonisolated private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
}
