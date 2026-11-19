import ActivityKit
import AppIntents
import Foundation
import QotKit
import WidgetKit

/// The Live Activity shown while a voice memo records (Lock Screen and
/// Dynamic Island). iOS stops a recording an intent started unless one runs.
struct MemoAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var startedAt: Date
    }
}

/// What the recording intents and the Control Center control share with the
/// app. This file is compiled into the app and the widget extension, but the
/// recorder lives in the app: the app sets `set` at launch, and iOS runs
/// these intents in the app's process (it launches it in the background).
enum MemoRecording {
    static let controlKind = "llc.abstractsyntax.qot.memo-control"

    /// Starts (true) or stops (false) a recording. Nil outside the app.
    @MainActor static var set: (@MainActor (Bool) async throws -> Void)?

    private static let key = "memo.recording"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: AppGroup.id) }

    /// Whether a memo is recording now: what the control shows. The app
    /// writes it, and clears it at launch (a recording never survives one).
    static var isRecording: Bool {
        get { defaults?.bool(forKey: key) ?? false }
        set {
            defaults?.set(newValue, forKey: key)
            ControlCenter.shared.reloadControls(ofKind: controlKind)
        }
    }

    @MainActor static func run(_ on: Bool) async throws {
        guard let set else { throw MemoIntentError.notInApp }
        try await set(on)
    }
}

enum MemoIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notInApp

    var localizedStringResource: LocalizedStringResource {
        "qot couldn't reach its recorder. Open qot and record from there."
    }
}

/// The Control Center control (also the Lock Screen's control slots and the
/// Action button): on records a voice memo without opening qot, off stops
/// and saves it.
struct ToggleMemoIntent: SetValueIntent, AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Record Voice Memo"
    static let description = IntentDescription(
        "Starts or stops a voice memo in qot without opening it.")
    static let isDiscoverable = false

    @Parameter(title: "Recording")
    var value: Bool

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        try await MemoRecording.run(value)
        return .result()
    }
}

/// Siri ("Record a memo in qot"), Shortcuts and the Action button.
struct StartMemoIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Record Voice Memo"
    static let description = IntentDescription(
        "Starts recording a voice memo in qot without opening it. The recording and its text are saved as a note.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try await MemoRecording.run(true)
        return .result()
    }
}

/// The Live Activity's stop button, Siri and Shortcuts.
struct StopMemoIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Voice Memo"
    static let description = IntentDescription("Stops the voice memo qot is recording and saves it.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try await MemoRecording.run(false)
        return .result()
    }
}
