import AppIntents
import QotKit
import WidgetKit

/// Saves a note without opening the app: Siri ("Capture a thought in qot"),
/// Shortcuts, the Action button (via a shortcut) and Spotlight. Saves first,
/// then syncs for at most 3 seconds, like `qot get …`.
struct AddNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Note"
    static let description = IntentDescription("Saves a note in qot without opening it.")

    @Parameter(
        title: "Note", inputOptions: String.IntentInputOptions(multiline: true),
        requestValueDialog: "What's the note?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to qot")
    }

    init() {}

    init(text: String) {
        self.text = text
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let result = try await Capture.onDevice(userAgent: UserAgent.value).add(text)
        WidgetCenter.shared.reloadAllTimelines()
        let dialog: IntentDialog =
            switch result.synced {
            case .synced, .signedOut: "Saved."
            case .later: "Saved. It will sync when qot can reach the server."
            }
        return .result(value: result.note.content, dialog: dialog)
    }
}

/// Siri phrases that work with no setup, and the shortcuts Spotlight and
/// the Action button offer. No phrase says "note": Siri hands "add a note
/// in qot" to Apple Notes, whose Siri extension then crashed ("something
/// went wrong", 2026-11-09). "Quantum of Thought" also works as the app's
/// name (`INAlternativeAppNames` in Info.plist).
struct QotShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddNoteIntent(),
            phrases: [
                "Capture a thought in \(.applicationName)",
                "Capture in \(.applicationName)",
                "Save a thought in \(.applicationName)",
                "Tell \(.applicationName) something",
            ],
            shortTitle: "Add Note",
            systemImageName: "square.and.pencil")
        AppShortcut(
            intent: OpenCaptureIntent(),
            phrases: ["Open \(.applicationName) to write"],
            shortTitle: "New Note",
            systemImageName: "square.and.pencil.circle")
    }
}
