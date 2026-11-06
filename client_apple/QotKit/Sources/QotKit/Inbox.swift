import Foundation

public enum InboxError: Error, Equatable, LocalizedError {
    case malformed

    public var errorDescription: String? { "A capture from the Watch was malformed." }
}

/// Captures sent from another device that can't save notes itself (the
/// Watch, which doesn't link qot_core in v1; see #35), as WatchConnectivity
/// user info: `{id, text}`. A transfer can be delivered more than once, so
/// recent ids are remembered (`inbox.json` beside the notes) and repeats
/// are dropped.
public struct Inbox: Sendable {
    /// The keys of a capture's user info; the Watch app sends the same.
    public static let idKey = "id"
    public static let textKey = "text"

    let store: NoteStore
    let remember: Int

    public init(store: NoteStore, remember: Int = 500) {
        self.store = store
        self.remember = remember
    }

    private var seenPath: URL { store.directory.appendingPathComponent("inbox.json") }

    /// Saves the capture as a note, or returns nil if it was saved before.
    @discardableResult
    public func receive(_ userInfo: [String: Any]) throws -> NoteItem? {
        guard let id = userInfo[Self.idKey] as? String, let text = userInfo[Self.textKey] as? String
        else { throw InboxError.malformed }
        return try FileLock.withLock(at: store.directory.appendingPathComponent("inbox.lock")) {
            var ids = try seen()
            if ids.contains(id) { return nil }
            let note = try store.add(text)
            ids.append(id)
            let data = try JSONEncoder().encode(Array(ids.suffix(remember)))
            try data.write(to: seenPath, options: .atomic)
            return note
        }
    }

    /// The ids remembered, oldest first.
    func seen() throws -> [String] {
        do {
            return try JSONDecoder().decode([String].self, from: Data(contentsOf: seenPath))
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
    }
}
