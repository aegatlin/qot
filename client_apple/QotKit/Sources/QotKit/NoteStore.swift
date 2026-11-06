import Foundation

/// What the apps show of a note.
public struct NoteItem: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let content: String
    public let createdAt: Date

    public init(id: String, content: String, createdAt: Date) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
    }
}

public enum NoteStoreError: Error, Equatable, LocalizedError {
    case blank
    case notFound(id: String)
    /// A note file that isn't a note, or a note operation that failed.
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .blank: "A note needs some text."
        case .notFound(let id): "No note \(id)."
        case .invalid(let message): message
        }
    }
}

/// Notes on this device, one Automerge file per note, in the same layout as
/// the CLI (`notes/<id>.note` under the data directory). The rules live in
/// qot_core; this is the file-system shell around them.
///
/// Errors are values: a file that can't be read fails the call instead of
/// being skipped, so a user's note is never silently dropped.
public final class NoteStore: Sendable {
    public let directory: URL
    private var notesDir: URL { directory.appendingPathComponent("notes", isDirectory: true) }

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("notes", isDirectory: true),
            withIntermediateDirectories: true)
    }

    /// Saves a new note. Capture never waits on the network.
    @discardableResult
    public func add(_ content: String) throws -> NoteItem {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NoteStoreError.blank
        }
        let note = Note(content: content)
        try save(note)
        return item(note)
    }

    /// Live notes, oldest first. Tombstones are hidden.
    public func list() throws -> [NoteItem] {
        try loadAll()
            .filter { !$0.isDeleted() }
            .map(item)
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    /// Marks a note deleted. The file stays, so the delete can sync.
    public func delete(id: String) throws {
        try withStoreLock {
            let note = try load(path(id))
            try save(wrap { try note.delete() })
        }
    }

    // MARK: - Sync

    /// Every stored note, tombstones included: what sync works on.
    public func allNotes() throws -> [Note] {
        try loadAll()
    }

    /// Saves notes, merging each with what is on disk now, so an edit made
    /// by another process since they were read is never overwritten.
    public func merge(_ notes: [Note]) throws {
        try withStoreLock {
            for note in notes {
                let current: Note?
                do {
                    current = try load(path(note.id()))
                } catch NoteStoreError.notFound {
                    current = nil
                }
                try save(try current.map { c in try wrap { try c.merge(other: note) } } ?? note)
            }
        }
    }

    /// What this device has synced, as the CLI keeps it in `sync.json`.
    /// Missing means never synced; unreadable is an error, not a fresh start
    /// (a fresh start would re-push everything, which is harmless, but a
    /// corrupt file is worth knowing about).
    public func loadSyncState() throws -> SyncState {
        let data: Data
        do {
            data = try Data(contentsOf: syncStatePath)
        } catch CocoaError.fileReadNoSuchFile {
            return .empty()
        }
        return try wrap { try SyncState.fromJson(json: String(decoding: data, as: UTF8.self)) }
    }

    public func saveSyncState(_ state: SyncState) throws {
        try Data(state.toJson().utf8).write(to: syncStatePath, options: .atomic)
    }

    /// Forgets what has been synced, so the next sign-in starts afresh.
    /// Notes stay.
    public func forgetSyncState() throws {
        do {
            try FileManager.default.removeItem(at: syncStatePath)
        } catch CocoaError.fileNoSuchFile {}
    }

    /// How many notes (tombstones included) have changes not pushed yet.
    public func unsyncedCount() throws -> Int {
        planPush(notes: try loadAll(), state: try loadSyncState()).count
    }

    // MARK: - Moving stores

    /// Moves the notes of an older store (the app's own Application Support,
    /// before the App Group) into this one, merging any both have, then
    /// removes them there. Safe to run on every launch.
    public func migrate(from oldDirectory: URL) throws {
        let old = oldDirectory.appendingPathComponent("notes", isDirectory: true)
        guard FileManager.default.fileExists(atPath: old.path) else { return }
        let files = try FileManager.default
            .contentsOfDirectory(at: old, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "note" }
        try merge(try files.map(load))
        for file in files { try FileManager.default.removeItem(at: file) }
    }

    // MARK: - Export

    /// Live notes, oldest first, as the CLI's `qot export` prints them: a
    /// JSON array of `{id, created_at, content}`.
    public func export() throws -> Data {
        let notes = try list().map {
            ["id": $0.id, "created_at": Export.timestamp($0.createdAt), "content": $0.content]
        }
        return try JSONSerialization.data(
            withJSONObject: notes, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: - Files

    private var syncStatePath: URL { directory.appendingPathComponent("sync.json") }

    /// Serialises read-modify-writes of notes across processes (the app,
    /// its intents and widgets share the store).
    private func withStoreLock<T>(_ body: () throws -> T) throws -> T {
        try FileLock.withLock(at: directory.appendingPathComponent("store.lock"), body)
    }

    private func path(_ id: String) -> URL {
        notesDir.appendingPathComponent("\(id).note")
    }

    private func save(_ note: Note) throws {
        try note.toBytes().write(to: path(note.id()), options: .atomic)
    }

    private func load(_ url: URL) throws -> Note {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            throw NoteStoreError.notFound(id: url.deletingPathExtension().lastPathComponent)
        }
        return try wrap { try Note.fromBytes(bytes: data) }
    }

    private func loadAll() throws -> [Note] {
        try FileManager.default
            .contentsOfDirectory(at: notesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "note" }
            .map(load)
    }

    private func item(_ note: Note) -> NoteItem {
        NoteItem(
            id: note.id(),
            content: note.content(),
            createdAt: Date(timeIntervalSince1970: Double(note.createdAtMs()) / 1000))
    }
}

public enum Export {
    /// RFC 3339 UTC to the second, as the CLI writes `created_at`.
    public static func timestamp(_ date: Date) -> String {
        let seconds = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        return seconds.formatted(.iso8601)
    }
}

/// Runs a qot_core call, turning its error into a `NoteStoreError`.
func wrap<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let error as QotError {
        throw NoteStoreError.invalid(error.localizedDescription)
    }
}
