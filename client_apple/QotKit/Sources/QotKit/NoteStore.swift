import Foundation

/// What the apps show of a note.
public struct NoteItem: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let content: String
    public let createdAt: Date
    /// The last edit, to the second; never before `createdAt`.
    public let updatedAt: Date
    /// Media on the note (a recording), oldest first. The bytes are in the
    /// store's `blobs/`, by the attachment's id, once this device has them.
    public let attachments: [Attachment]

    public init(
        id: String, content: String, createdAt: Date, updatedAt: Date? = nil,
        attachments: [Attachment] = []
    ) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.attachments = attachments
    }

    /// Nothing to keep: no text and no attachments. An editor discards such
    /// a note; a recording with no text is not one.
    public var isEmpty: Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }
}

/// A recording whose transcript isn't in its note yet.
public struct PendingTranscript: Equatable, Sendable {
    public let note: NoteItem
    public let attachment: Attachment
    /// The recording on this device, if it is here.
    public let file: URL?
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
/// the CLI (`notes/<id>.note` under the data directory), and attachments'
/// bytes beside them (`blobs/<attachment id>`). The rules live in qot_core;
/// this is the file-system shell around them.
///
/// Errors are values: a file that can't be read fails the call instead of
/// being skipped, so a user's note is never silently dropped.
public final class NoteStore: Sendable {
    public let directory: URL
    private var notesDir: URL { directory.appendingPathComponent("notes", isDirectory: true) }
    private var blobsDir: URL { directory.appendingPathComponent("blobs", isDirectory: true) }

    public init(directory: URL) throws {
        self.directory = directory
        for name in ["notes", "blobs"] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true)
        }
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

    /// Replaces a note's text, merging the edit into the note as it is on
    /// disk now (another process may have changed it). Blank is allowed: the
    /// editor saves as you type.
    @discardableResult
    public func update(id: String, content: String) throws -> NoteItem {
        try withStoreLock {
            let note = try load(path(id))
            guard note.content() != content else { return item(note) }
            let edited = try wrap { try note.update(content: content) }
            try save(edited)
            return item(edited)
        }
    }

    /// Marks a note deleted. The file stays, so the delete can sync; its
    /// recordings go from this device now, and the next sync tells the server.
    public func delete(id: String) throws {
        try withStoreLock {
            let note = try load(path(id))
            try save(wrap { try note.delete() })
            try discardUnreferencedBlobs()
        }
    }

    // MARK: - Voice memos

    /// Saves a voice memo: a note whose text is the transcript and whose
    /// attachment is the recording. `recording` is a finished file somewhere
    /// outside the store; it is moved into `blobs/` in the same locked step
    /// that saves the note, so a sync never sees one without the other.
    /// `transcript` nil means not transcribed yet (`fillTranscript` later);
    /// empty means nothing was heard.
    @discardableResult
    public func addMemo(recording: URL, mediaType: String, durationMs: UInt64, transcript: String?)
        throws -> NoteItem
    {
        let size = try recording.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw NoteStoreError.invalid("The recording is empty.") }
        let attachment = Attachment(
            id: newAttachmentId(), kind: "audio", mediaType: mediaType, size: UInt64(size),
            durationMs: durationMs, text: transcript == nil ? .pending : .done)
        let text = (transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let note = try wrap { try Note.withAttachment(content: text, attachment: attachment) }
        return try withStoreLock {
            try FileManager.default.moveItem(at: recording, to: blobPath(attachment.id))
            do {
                try save(note)
            } catch {
                try? FileManager.default.removeItem(at: blobPath(attachment.id))
                throw error
            }
            return item(note)
        }
    }

    /// Writes a recording's transcript into its note, once (the core's
    /// `fill_text`): nothing changes if it was already filled in.
    @discardableResult
    public func fillTranscript(noteID: String, attachmentID: String, text: String) throws -> NoteItem {
        try withStoreLock {
            let note = try load(path(noteID))
            let filled = try wrap { try note.fillText(id: attachmentID, text: text) }
            if filled.heads() != note.heads() { try save(filled) }
            return item(filled)
        }
    }

    /// Recordings on live notes still waiting for their transcript.
    public func pendingTranscripts() throws -> [PendingTranscript] {
        try list().flatMap { note in
            note.attachments.filter { $0.text == .pending }.map {
                PendingTranscript(note: note, attachment: $0, file: localBlob($0.id))
            }
        }
    }

    /// Removes an attachment and keeps the note's text.
    @discardableResult
    public func removeAttachment(noteID: String, attachmentID: String) throws -> NoteItem {
        try withStoreLock {
            let note = try load(path(noteID))
            let removed = try wrap { try note.detach(id: attachmentID) }
            try save(removed)
            try discardUnreferencedBlobs()
            return item(removed)
        }
    }

    // MARK: - Recordings in progress

    private var recordingsDir: URL {
        directory.appendingPathComponent("recordings", isDirectory: true)
    }

    /// Where a recorder writes a new recording: in the store's
    /// `recordings/`, not `blobs/`, so no sync sees or sweeps it until
    /// `addMemo` moves it in beside its note.
    public func newRecordingURL() throws -> URL {
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        return recordingsDir.appendingPathComponent("\(UUID().uuidString).m4a")
    }

    /// Recordings never handed to `addMemo`: the app was killed while one
    /// was being made. Oldest first.
    public func strandedRecordings() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: recordingsDir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: recordingsDir, includingPropertiesForKeys: [.creationDateKey]
        )
        .filter { !$0.lastPathComponent.hasPrefix(".") }
        .sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return (a, $0.path) < (b, $1.path)
        }
    }

    // MARK: - Blobs

    /// An attachment's bytes on this device, if they are here.
    public func localBlob(_ id: String) -> URL? {
        let url = blobPath(id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The attachments whose bytes this device holds.
    public func blobIDs() throws -> [String] {
        try FileManager.default.contentsOfDirectory(at: blobsDir, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    /// Keeps bytes fetched from the server.
    @discardableResult
    public func saveBlob(_ id: String, _ data: Data) throws -> URL {
        try data.write(to: blobPath(id), options: .atomic)
        return blobPath(id)
    }

    public func removeBlobs(_ ids: [String]) throws {
        for id in ids {
            do {
                try FileManager.default.removeItem(at: blobPath(id))
            } catch CocoaError.fileNoSuchFile {}
        }
    }

    /// Deletes the blob files no live note refers to (the core's
    /// `plan_blobs`); returns their ids. It doesn't touch the sync state: a
    /// sync forgets them there.
    @discardableResult
    func discardUnreferencedBlobs(state: SyncState? = nil) throws -> [String] {
        let plan = planBlobs(
            notes: try loadAll(), state: try state ?? loadSyncState(), local: try blobIDs())
        try removeBlobs(plan.discard)
        return plan.discard
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
    /// JSON array of `{id, created_at, content}`, with `attachments` on a
    /// note that has any.
    public func export() throws -> Data {
        let notes = try list().map { note -> [String: Any] in
            var entry: [String: Any] = [
                "id": note.id, "created_at": Export.timestamp(note.createdAt), "content": note.content,
            ]
            if !note.attachments.isEmpty {
                entry["attachments"] = note.attachments.map { a -> [String: Any] in
                    var attachment: [String: Any] = [
                        "id": a.id, "kind": a.kind, "media_type": a.mediaType, "size": a.size,
                    ]
                    if let duration = a.durationMs { attachment["duration_ms"] = duration }
                    return attachment
                }
            }
            return entry
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

    private func blobPath(_ id: String) -> URL {
        blobsDir.appendingPathComponent(id)
    }

    /// Runs `body` holding the store lock, for a sync's blob clean-up.
    func locked<T>(_ body: () throws -> T) throws -> T {
        try withStoreLock(body)
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
            createdAt: Date(timeIntervalSince1970: Double(note.createdAtMs()) / 1000),
            updatedAt: Date(timeIntervalSince1970: Double(note.updatedAtMs()) / 1000),
            attachments: note.attachments())
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
