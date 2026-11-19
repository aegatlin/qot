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

    public let store: NoteStore
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

    /// Saves a voice memo (`NoteStore.addMemo`), then syncs like `add`. The
    /// note and its text usually make it within `limit`; a long recording's
    /// upload may not, and goes up with the next sync.
    public func addMemo(
        recording: URL, mediaType: String, durationMs: UInt64, transcript: String?,
        syncFor limit: Duration = .seconds(3)
    ) async throws -> Result {
        let note = try store.addMemo(
            recording: recording, mediaType: mediaType, durationMs: durationMs, transcript: transcript)
        NotesChanged.post()
        return Result(note: note, synced: await sync(within: limit))
    }

    /// Turns a recording into text. Nil: this device can't (no speech model
    /// for the language), so don't ask again. Throwing: try again later.
    public typealias Transcribe = @Sendable (URL) async throws -> String?

    public struct MemoResult: Sendable {
        public let note: NoteItem
        public let synced: Synced
        /// False while the transcript still waits (`transcribePending`).
        public let transcribed: Bool
    }

    /// What happens when a recording stops, in the order that loses least
    /// if the app is suspended part-way: save the memo without text, send
    /// the note and the audio, then transcribe, write the text in and sync
    /// again. Only a failure to save throws.
    public func finishMemo(
        recording: URL, mediaType: String, durationMs: UInt64, transcribe: Transcribe,
        syncFor limit: Duration = .seconds(25)
    ) async throws -> MemoResult {
        let saved = try store.addMemo(
            recording: recording, mediaType: mediaType, durationMs: durationMs, transcript: nil)
        NotesChanged.post()
        var synced = await sync(within: limit)
        guard let audio = saved.attachments.first, let file = store.localBlob(audio.id),
            let note = await fill(noteID: saved.id, attachmentID: audio.id, file: file, transcribe)
        else { return MemoResult(note: saved, synced: synced, transcribed: false) }
        synced = await sync(within: limit)
        return MemoResult(note: note, synced: synced, transcribed: true)
    }

    /// Transcribes the recordings made on this device that still wait for
    /// their text (a transcription that failed, or was cut off), then
    /// syncs. Returns how many were filled in.
    @discardableResult
    public func transcribePending(_ transcribe: Transcribe, syncFor limit: Duration = .seconds(25))
        async -> Int
    {
        var filled = 0
        for waiting in (try? store.pendingTranscripts()) ?? [] {
            // No file: recorded on another device, which will transcribe it.
            guard let file = waiting.file else { continue }
            let note = await fill(
                noteID: waiting.note.id, attachmentID: waiting.attachment.id, file: file, transcribe)
            if note != nil { filled += 1 }
        }
        if filled > 0 {
            NotesChanged.post()
            _ = await sync(within: limit)
        }
        return filled
    }

    /// Nil if the transcript still waits.
    private func fill(noteID: String, attachmentID: String, file: URL, _ transcribe: Transcribe) async
        -> NoteItem?
    {
        let heard: String?
        do {
            heard = try await transcribe(file)
        } catch {
            return nil
        }
        // Nothing heard, or this device can't transcribe: marked done with
        // no text, so it isn't asked again.
        let note = try? store.fillTranscript(
            noteID: noteID, attachmentID: attachmentID, text: heard ?? "")
        NotesChanged.post()
        return note
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
    /// The most recently edited live notes, newest edit first (for widgets),
    /// in the same order as the app's list.
    public func latest(_ count: Int) throws -> [NoteItem] {
        Array(NoteList.byLastEdit(try list()).prefix(count))
    }
}
