import AVFoundation
import Observation
import Speech

/// Capture by voice: transcribes on the device (never sent to a server, so
/// notes stay private before end-to-end encryption exists) into the draft,
/// for the person to check and save. Audio is not kept: notes are text.
@MainActor @Observable
final class Dictation {
    private(set) var listening = false
    /// What has been heard so far in this dictation.
    private(set) var transcript = ""
    private(set) var problem: String?

    private var engine: AVAudioEngine?
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func toggle() async {
        if listening { stop() } else { await start() }
    }

    func start() async {
        problem = nil
        transcript = ""
        guard await Self.authorized() else {
            problem = "qot needs the microphone and speech recognition, in Settings."
            return
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable,
            recognizer.supportsOnDeviceRecognition
        else {
            problem = "On-device speech recognition isn't available for your language."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.addsPunctuation = true

            let engine = AVAudioEngine()
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) {
                buffer, _ in request.append(buffer)
            }
            engine.prepare()
            try engine.start()

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let done = error != nil || (result?.isFinal ?? false)
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if done { self.stop() }
                }
            }
            self.engine = engine
            self.request = request
            listening = true
        } catch {
            problem = error.localizedDescription
            stop()
        }
    }

    func stop() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        engine = nil
        request = nil
        task = nil
        listening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func authorized() async -> Bool {
        let speech = await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
