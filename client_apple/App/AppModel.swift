import Foundation
import Observation
import QotKit

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
                ServerAPI(baseURL: base, transport: AppModel.session, userAgent: AppModel.userAgent)
            }
        }
        session = try? account?.current()
        reload()
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

    /// Saves a note. Returns whether it was saved, so the field can clear.
    func add(_ content: String) -> Bool {
        let saved = perform { _ = try $0.add(content) }
        if saved { syncInBackground() }
        return saved
    }

    func delete(_ note: NoteItem) {
        if perform({ try $0.delete(id: note.id) }) { syncInBackground() }
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
            notes = try store.list().reversed()
            unsynced = try store.unsyncedCount()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - Sync

    func syncInBackground() {
        Task { await sync() }
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

    nonisolated static let userAgent: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = [os.majorVersion, os.minorVersion] + (os.patchVersion > 0 ? [os.patchVersion] : [])
        return ServerAPI.userAgent(
            appVersion: version, osName: "iOS",
            osVersion: osVersion.map(String.init).joined(separator: "."), model: modelIdentifier())
    }()

    /// e.g. `iPhone18,1`; in the simulator, the simulated model's.
    nonisolated private static func modelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
