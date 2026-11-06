import Foundation

/// Capture from outside the app (App Intents, Siri, the Action button, the
/// Watch through the phone): save first, then a sync bounded in time, like
/// the CLI's `qot get …`. The note is saved whatever the network does.
public struct Capture: Sendable {
    public enum Synced: Equatable, Sendable {
        case synced
        /// Offline, slow or refused: it goes up with the next sync.
        case later
        /// Not signed in; the note stays on this device.
        case signedOut
    }

    public struct Result: Sendable {
        public let note: NoteItem
        public let synced: Synced
    }

    let store: NoteStore
    let syncer: Syncer

    public init(store: NoteStore, syncer: Syncer) {
        self.store = store
        self.syncer = syncer
    }

    /// The shared App Group store and Keychain session.
    public static func onDevice(userAgent: String) throws -> Capture {
        let store = try AppGroup.store()
        let syncer = Syncer(store: store, credentials: AppGroup.credentials()) { base in
            ServerAPI(baseURL: base, transport: URLSession.shared, userAgent: userAgent)
        }
        return Capture(store: store, syncer: syncer)
    }

    public func add(_ text: String, syncFor limit: Duration = .seconds(3)) async throws -> Result {
        let note = try store.add(text)
        NotesChanged.post()
        return Result(note: note, synced: await sync(within: limit))
    }

    /// Syncs, giving up after `limit`.
    public func sync(within limit: Duration) async -> Synced {
        await withTaskGroup(of: Synced.self) { group in
            group.addTask {
                do {
                    try await syncer.sync()
                    return .synced
                } catch SyncError.signedOut {
                    return .signedOut
                } catch {
                    return .later
                }
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return .later
            }
            let first = await group.next() ?? .later
            group.cancelAll()
            return first
        }
    }
}

/// Tells the app that notes changed outside its model (an intent ran in the
/// app's process, a Watch capture arrived), so it reloads.
public enum NotesChanged {
    public static let name = Notification.Name("llc.abstractsyntax.qot.notesChanged")

    public static func post() {
        NotificationCenter.default.post(name: name, object: nil)
    }
}

extension NoteStore {
    /// The newest live notes, newest first (for widgets).
    public func latest(_ count: Int) throws -> [NoteItem] {
        Array(try list().suffix(count).reversed())
    }
}
