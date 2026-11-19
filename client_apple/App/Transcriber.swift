import AVFoundation
import Foundation
import Speech

/// A recording's text, made on this device (`SpeechAnalyzer`): the server
/// never hears a memo. Nil when this device can't transcribe (no on-device
/// model for the language); throws when it could but didn't this time (the
/// model is still downloading), so it is tried again at the next launch.
enum Transcriber {
    static func transcribe(_ file: URL) async throws -> String? {
        guard SpeechTranscriber.isAvailable,
            let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
        else { return nil }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        // The store keeps recordings without an extension; audio readers
        // want one.
        let named = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).m4a")
        do {
            try FileManager.default.linkItem(at: file, to: named)
        } catch {
            try FileManager.default.copyItem(at: file, to: named)
        }
        defer { try? FileManager.default.removeItem(at: named) }
        let audio = try AVAudioFile(forReading: named)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let reading = Task {
            var text = ""
            for try await result in transcriber.results {
                text += String(result.text.characters)
            }
            return text
        }
        do {
            if let end = try await analyzer.analyzeSequence(from: audio) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            reading.cancel()
            throw error
        }
        return try await reading.value
    }
}
