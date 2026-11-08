import Foundation

/// Where every Apple target (the app, its intents and widgets, later the
/// Mac) finds the shared note store and session. The Watch doesn't: it
/// hands notes to the phone over WatchConnectivity.
public enum AppGroup {
    public static let id = "group.llc.abstractsyntax.qot"

    /// The note store in the App Group container, with notes from before the
    /// App Group (the app's own Application Support) moved in. Without the
    /// container (e.g. an unsigned preview) the app's own directory is used.
    public static func store() throws -> NoteStore {
        let legacy = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        guard
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: id)
        else { return try NoteStore(directory: legacy) }
        let store = try NoteStore(directory: container.appendingPathComponent("qot", isDirectory: true))
        try store.migrate(from: legacy)
        return store
    }

    /// The session, in the Keychain, shared through the App Group.
    public static func credentials() -> KeychainCredentialStore {
        KeychainCredentialStore(accessGroup: id)
    }
}
