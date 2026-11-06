import Foundation
import QotKit
import WatchConnectivity
import WidgetKit

/// Receives captures from the Watch (WatchConnectivity `transferUserInfo`,
/// queued while the devices are apart) and saves them as notes, then syncs
/// for a moment, like any capture.
final class WatchReceiver: NSObject, WCSessionDelegate, Sendable {
    static let shared = WatchReceiver()

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let capture = try? Capture.onDevice(userAgent: UserAgent.value) else { return }
        let inbox = Inbox(store: capture.store)
        do {
            guard try inbox.receive(userInfo) != nil else { return }
        } catch {
            return  // malformed or blank: nothing to save
        }
        NotesChanged.post()
        WidgetCenter.shared.reloadAllTimelines()
        Task { _ = await capture.sync(within: .seconds(10)) }
    }

    func session(
        _ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?
    ) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
