import ActivityKit
import AVFoundation
import Observation
import QotKit
import UIKit
import WidgetKit

enum MemoError: Error, LocalizedError, CustomLocalizedStringResourceConvertible {
    case microphone
    case couldNotStart
    case session(String)

    var errorDescription: String? {
        switch self {
        case .session(let why): "qot couldn't take the microphone: \(why)"
        case .microphone:
            "qot needs the microphone. Open qot and record a memo there once, or allow it in Settings."
        case .couldNotStart: "qot couldn't start recording."
        }
    }

    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: errorDescription ?? "")
    }
}

/// Records voice memos: unlike dictation (`Dictation`), the recording is
/// kept, saved as a note's attachment and synced, with its text made on
/// this device afterwards. One recorder for the app, the Control Center
/// control, Siri and the Live Activity's stop button, which all run in the
/// app's process.
///
/// The file is AAC in an .m4a, mono, 64 kbps (about half a megabyte a
/// minute; every browser and Apple device plays it), written to the store's
/// `recordings/` and handed to `Capture.finishMemo` when it stops.
@MainActor @Observable
final class MemoRecorder: NSObject, AVAudioRecorderDelegate {
    static let shared = MemoRecorder()
    /// A memo stops itself here: about 14 MB, under the server's 25 MB.
    static let limit: TimeInterval = 30 * 60
    static let mediaType = "audio/mp4"

    /// When the recording in progress started; nil when not recording.
    private(set) var startedAt: Date?
    var recording: Bool { startedAt != nil }
    /// Why the last memo couldn't be saved, for the app to show.
    var problem: String?

    private var recorder: AVAudioRecorder?
    private var file: URL?
    private var interruptions: NSObjectProtocol?

    /// Called once when the app's process starts (in front, or in the
    /// background for an intent): takes the intents' calls, and finishes
    /// what a previous run left (a recording cut off by the app being
    /// killed, a transcript that failed).
    func launch() {
        MemoRecording.set = { [weak self] on in
            guard let self else { return }
            if on { try await self.start() } else { await self.stop() }
        }
        MemoRecording.isRecording = false
        // Listed now, before anything can start a new recording.
        let stranded = (try? AppGroup.store().strandedRecordings()) ?? []
        Task {
            await Self.endActivities()
            let background = UIApplication.shared.beginBackgroundTask(withName: "qot.memo.launch")
            for file in stranded { await self.save(file) }
            _ = try? await self.capture().transcribePending(Transcriber.transcribe)
            UIApplication.shared.endBackgroundTask(background)
        }
    }

    func toggle() async {
        if recording {
            await stop()
        } else {
            do {
                try await start()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    func start() async throws {
        guard !recording else { return }
        switch AVAudioApplication.shared.recordPermission {
        case .granted: break
        case .undetermined:
            // The question can only be shown with the app in front; an
            // intent before the first in-app recording says to open qot.
            guard UIApplication.shared.applicationState == .active,
                await AVAudioApplication.requestRecordPermission()
            else { throw MemoError.microphone }
        default: throw MemoError.microphone
        }

        // The Live Activity comes first: started from an intent with the
        // app in the background, iOS lets the app take the microphone only
        // while one is showing.
        let now = Date.now
        var activityProblem: String?
        do {
            _ = try Activity.request(
                attributes: MemoAttributes(),
                content: .init(state: .init(startedAt: now), staleDate: now + Self.limit + 60))
        } catch {
            activityProblem = "\(error)"
        }
        let file: URL
        let recorder: AVAudioRecorder
        do {
            file = try AppGroup.store().newRecordingURL()
            do {
                try Self.activateSession()
            } catch {
                // Say everything known: this can only be read off a phone.
                let live = activityProblem.map { "no Live Activity: \($0)" } ?? "Live Activity started"
                let state = UIApplication.shared.applicationState == .active ? "in front" : "in the background"
                throw MemoError.session("\(error.localizedDescription) (\((error as NSError).code); \(state); \(live))")
            }
            recorder = try AVAudioRecorder(
                url: file,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64_000,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                ])
            recorder.delegate = self
            guard recorder.record(forDuration: Self.limit) else {
                try? FileManager.default.removeItem(at: file)
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                throw MemoError.couldNotStart
            }
        } catch {
            await Self.endActivities()
            throw error
        }
        self.recorder = recorder
        self.file = file
        startedAt = now
        MemoRecording.isRecording = true
        // A phone call or Siri takes the microphone: keep what was said.
        interruptions = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            let began =
                note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                == AVAudioSession.InterruptionType.began.rawValue
            if began { Task { @MainActor in await self?.stop() } }
        }
    }

    /// Takes the microphone. A recording-only session first; started in the
    /// background iOS can refuse that one (`cannotInterruptOthers`, seen on
    /// a phone 2026-11-20 from the Control Center control), so then one
    /// that mixes with other audio, which may be activated there.
    private static func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
        } catch {
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        }
    }

    /// Stops the recording. Saving, sending and transcribing carry on after
    /// this returns (an intent shouldn't wait for them), under a background
    /// task taken before it does, so iOS gives the app time to finish.
    func stop() async {
        guard let recorder else { return }
        // Closes the file; `finished` does the rest (the delegate call this
        // also causes then finds nothing to do).
        recorder.stop()
        finished()
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // Reached the limit (or `stop` got here first).
        Task { @MainActor in self.finished() }
    }

    private func finished() {
        guard let file else { return }
        let background = UIApplication.shared.beginBackgroundTask(withName: "qot.memo")
        self.file = nil
        recorder = nil
        startedAt = nil
        if let interruptions { NotificationCenter.default.removeObserver(interruptions) }
        interruptions = nil
        MemoRecording.isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        Task {
            await Self.endActivities()
            await save(file)
            UIApplication.shared.endBackgroundTask(background)
        }
    }

    /// Hands a closed recording to the store, then syncs and transcribes.
    private func save(_ file: URL) async {
        let seconds = (try? await AVURLAsset(url: file).load(.duration).seconds) ?? 0
        guard seconds.isFinite, seconds >= 0.5 else {
            // A tap on and off, or a file cut off before it was playable.
            try? FileManager.default.removeItem(at: file)
            return
        }
        do {
            _ = try await capture().finishMemo(
                recording: file, mediaType: Self.mediaType, durationMs: UInt64(seconds * 1000),
                transcribe: Transcriber.transcribe)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            // Not saved: the file stays in `recordings/` for the next launch.
            problem = error.localizedDescription
        }
    }

    private nonisolated static func endActivities() async {
        for activity in Activity<MemoAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func capture() throws -> Capture {
        try Capture.onDevice(userAgent: UserAgent.value)
    }
}
