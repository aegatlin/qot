import SwiftUI
import WatchConnectivity

/// Capture on the Watch. The Watch doesn't link qot_core in v1 (#35): it
/// sends the text to the iPhone, which saves and syncs it. Transfers queue
/// while the phone is away and are delivered when it's back.
@main
struct QotWatchApp: App {
    @State private var outbox = Outbox()

    var body: some Scene {
        WindowGroup {
            CaptureView(outbox: outbox)
        }
    }
}

struct CaptureView: View {
    let outbox: Outbox
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            List {
                // Tapping the field offers dictation, Scribble and the keyboard.
                TextField("New note", text: $draft)
                    .onSubmit(send)
                if let sent = outbox.lastSent {
                    Section {
                        Label(sent, systemImage: "checkmark.circle")
                            .lineLimit(2)
                    } footer: {
                        Text(
                            outbox.waiting > 0
                                ? "\(outbox.waiting) waiting for your iPhone." : "Sent to your iPhone.")
                    }
                }
            }
            .navigationTitle("qot")
        }
        .onOpenURL { _ in draft = "" }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        outbox.send(text)
        draft = ""
    }
}

/// Sends captures to the iPhone as `{id, text}` user info (QotKit's
/// `Inbox` keys); the id lets the phone drop a transfer delivered twice.
@MainActor @Observable
final class Outbox {
    private(set) var lastSent: String?
    private(set) var waiting = 0
    private let session = WCSession.default
    private let delegate = SessionDelegate()

    init() {
        session.delegate = delegate
        session.activate()
        waiting = session.outstandingUserInfoTransfers.count
    }

    func send(_ text: String) {
        session.transferUserInfo(["id": UUID().uuidString, "text": text])
        lastSent = text
        waiting = session.outstandingUserInfoTransfers.count
    }
}

final class SessionDelegate: NSObject, WCSessionDelegate {
    func session(
        _ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?
    ) {}
}
