import Foundation

/// What the apps show of a note.
public struct NoteItem: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let content: String
    public let createdAt: Date
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
        let note = try load(path(id))
        try save(wrap { try note.delete() })
    }

    // MARK: - Files

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

/// Runs a qot_core call, turning its error into a `NoteStoreError`.
private func wrap<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let error as QotError {
        throw NoteStoreError.invalid(error.localizedDescription)
    }
}
