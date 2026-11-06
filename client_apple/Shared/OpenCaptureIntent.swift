import AppIntents
import Foundation

/// Opens qot with the cursor in the capture field. The Control Center
/// control runs it, so it is compiled into the app and the widget extension;
/// it runs in the app.
struct OpenCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "New Note"
    static let description = IntentDescription("Opens qot ready to type a note.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: OpenCaptureIntent.focusCapture, object: nil)
        return .result()
    }

    static let focusCapture = Notification.Name("llc.abstractsyntax.qot.focusCapture")

    /// Lock Screen and Home Screen widgets open this URL.
    static let url = URL(string: "qot://capture")!
}
