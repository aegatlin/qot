import AVFoundation
import Observation
import QotKit
import SwiftUI

/// A note's attachments, above its text: a recording plays; a kind this
/// build doesn't know is named and left alone.
struct AttachmentList: View {
    let attachments: [QotKit.Attachment]
    let model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            ForEach(attachments, id: \.id) { attachment in
                if attachment.kind == "audio" {
                    RecordingRow(attachment: attachment, model: model)
                } else {
                    Label(attachmentLabel(attachment: attachment), systemImage: "paperclip")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// One recording: play and pause, a scrubber and the time. The bytes come
/// from this device, else from the server the first time (then kept); until
/// the device that recorded it has sent them, it says so and asks again.
struct RecordingRow: View {
    let attachment: QotKit.Attachment
    let model: AppModel

    private enum Source: Equatable {
        case loading
        case onItsWay
        case failed(String)
        case ready(URL)
    }

    @State private var source = Source.loading
    @State private var player = MemoPlayer()

    private var length: TimeInterval {
        player.duration > 0 ? player.duration : TimeInterval(attachment.durationMs ?? 0) / 1000
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Button {
                    if case .ready(let file) = source {
                        player.toggle(file, mediaType: attachment.mediaType)
                    }
                } label: {
                    Label(
                        player.playing ? "Pause" : "Play",
                        systemImage: player.playing ? "pause.fill" : "play.fill"
                    )
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 32, height: 32)
                }
                .disabled(!isReady)
                TimelineView(.animation(minimumInterval: 0.2, paused: !player.playing)) { _ in
                    HStack(spacing: 12) {
                        Slider(
                            value: Binding(get: { player.time }, set: { player.seek($0) }),
                            in: 0...max(length, 0.1)
                        )
                        .disabled(!isReady)
                        .accessibilityLabel("Position")
                        Text(Self.clock(player.playing || player.time > 0 ? player.time : length))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let note = status {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.fill.tertiary, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NoteList.title(of: attachment))
        .task(id: attachment.id) { await load() }
        .onDisappear { player.stop() }
    }

    private var isReady: Bool {
        if case .ready = source { true } else { false }
    }

    private var status: String? {
        switch source {
        case .loading, .ready: player.problem
        case .onItsWay: BlobError.notOnServerYet.localizedDescription
        case .failed(let message): message
        }
    }

    private func load() async {
        while !Task.isCancelled {
            do {
                source = .ready(try await model.recording(attachment.id))
                return
            } catch BlobError.notOnServerYet {
                source = .onItsWay
            } catch SyncError.signedOut {
                source = .failed("Sign in to play this recording here.")
                return
            } catch {
                source = .failed(error.localizedDescription)
            }
            try? await Task.sleep(for: .seconds(10))
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Plays one recording.
@MainActor @Observable
final class MemoPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var playing = false
    private(set) var problem: String?
    private var player: AVAudioPlayer?

    var duration: TimeInterval { player?.duration ?? 0 }
    var time: TimeInterval { player?.currentTime ?? 0 }

    func toggle(_ file: URL, mediaType: String) {
        if playing {
            player?.pause()
            playing = false
            return
        }
        do {
            if player == nil {
                // The store keeps recordings without an extension.
                let hint = mediaType == "audio/mp4" ? AVFileType.m4a.rawValue : nil
                let made = try AVAudioPlayer(contentsOf: file, fileTypeHint: hint)
                made.delegate = self
                player = made
            }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            playing = player?.play() ?? false
            problem = nil
        } catch {
            problem = "This recording can't be played here."
        }
    }

    func seek(_ time: TimeInterval) {
        player?.currentTime = time
    }

    func stop() {
        player?.stop()
        if playing {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        playing = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.playing = false
            self.player?.currentTime = 0
        }
    }
}

/// The list's record button: one tap starts a voice memo, the next stops
/// and saves it.
struct RecordButton: View {
    let recorder: MemoRecorder

    var body: some View {
        Button {
            Task { await recorder.toggle() }
        } label: {
            Label(
                recorder.recording ? "Stop Recording" : "Record Voice Memo",
                systemImage: recorder.recording ? "stop.circle.fill" : "mic")
        }
        .tint(recorder.recording ? .red : nil)
        .symbolEffect(.pulse, isActive: recorder.recording)
    }
}
