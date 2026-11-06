import Foundation

/// The few Phoenix channel frames qot needs (serializer v2: a JSON array of
/// `[join_ref, ref, topic, event, payload]`). Pure, so they're tested
/// without a socket.
public enum PhoenixFrame {
    case join(topic: String, ref: String)
    case heartbeat(ref: String)

    public var text: String {
        switch self {
        case .join(let topic, let ref): #"["\#(ref)","\#(ref)",\#(quoted(topic)),"phx_join",{}]"#
        case .heartbeat(let ref): #"[null,"\#(ref)","phoenix","heartbeat",{}]"#
        }
    }

    /// The server's "this account's log grew" broadcast on `topic`.
    public static func isNudge(_ text: String, topic: String) -> Bool {
        guard let frame = parse(text) else { return false }
        return frame[2] as? String == topic && frame[3] as? String == "changed"
    }

    /// The reply to our join, refusing it.
    public static func joinRefused(_ text: String) -> Bool {
        guard let frame = parse(text), frame[3] as? String == "phx_reply",
            let payload = frame[4] as? [String: Any]
        else { return false }
        return frame[0] as? String != nil && payload["status"] as? String == "error"
    }

    private static func parse(_ text: String) -> [Any]? {
        guard let array = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any],
            array.count == 5
        else { return nil }
        return array
    }

    private func quoted(_ s: String) -> String {
        String(decoding: try! JSONEncoder().encode(s), as: UTF8.self)
    }
}

/// Live updates while the app is open: the server nudges
/// `notes:user:<id>` whenever this account's log grows, and a nudge only
/// triggers a sync, so data still moves through one path (pull). On a drop
/// it reconnects with backoff and asks for a sync, to catch up on anything
/// missed meanwhile.
public final class LiveNudges: Sendable {
    private let task: Task<Void, Never>

    public static func socketURL(server: URL, token: String) -> URL {
        var parts = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        parts.scheme = parts.scheme == "http" ? "ws" : "wss"
        parts.path = "/socket/websocket"
        parts.queryItems = [URLQueryItem(name: "token", value: token), URLQueryItem(name: "vsn", value: "2.0.0")]
        return parts.url!
    }

    /// - Parameters:
    ///   - credentials: read on every (re)connect, for a fresh access token.
    ///   - onNudge: the log grew, or the socket came back after a drop.
    public init(credentials: CredentialStore, onNudge: @escaping @Sendable () async -> Void) {
        task = Task {
            var backoff = 1
            var connectedBefore = false
            while !Task.isCancelled {
                guard let creds = try? credentials.load() else { return }
                let joined = await Self.session(creds, rejoined: connectedBefore, onNudge: onNudge)
                if joined {
                    connectedBefore = true
                    backoff = 1
                }
                if Task.isCancelled { return }
                // A refused connect usually means an expired token; a sync
                // refreshes it before the next try.
                await onNudge()
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 60)
            }
        }
    }

    public func stop() {
        task.cancel()
    }

    deinit {
        task.cancel()
    }

    /// One connection, until it drops. Whether the join succeeded.
    private static func session(
        _ creds: Credentials, rejoined: Bool, onNudge: @Sendable () async -> Void
    ) async -> Bool {
        let socket = URLSession.shared.webSocketTask(
            with: socketURL(server: creds.server, token: creds.accessToken))
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        let topic = "notes:user:\(creds.userId)"
        let heartbeat = Task {
            var ref = 2
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                ref += 1
                try? await socket.send(.string(PhoenixFrame.heartbeat(ref: "\(ref)").text))
            }
        }
        defer { heartbeat.cancel() }

        var joined = false
        do {
            try await socket.send(.string(PhoenixFrame.join(topic: topic, ref: "1").text))
            while !Task.isCancelled {
                guard case .string(let text) = try await socket.receive() else { continue }
                if PhoenixFrame.joinRefused(text) { break }
                if !joined, text.contains(#""phx_reply""#), text.contains(#""ok""#) {
                    joined = true
                    if rejoined { await onNudge() }
                } else if PhoenixFrame.isNudge(text, topic: topic) {
                    await onNudge()
                }
            }
        } catch {}
        return joined
    }
}
