import Foundation
import WhisperKit

/// Lokale Spracherkennung mit Whisper (Core ML) über WhisperKit. Alle Modelldateien liegen lokal, es wird nichts geladen.
final class Transcriber: @unchecked Sendable {
    static var modelFolder: URL? { ModelLocator.url("Optional/whisper-large-v3-turbo") }
    static var isAvailable: Bool {
        guard let f = modelFolder else { return false }
        return FileManager.default.fileExists(atPath: f.appendingPathComponent("tokenizer.json").path)
    }

    private var kit: WhisperKit?

    private func load() async throws -> WhisperKit {
        if let k = kit { return k }
        guard let folder = Self.modelFolder else { throw CocoaError(.fileNoSuchFile) }
        let config = WhisperKitConfig(modelFolder: folder.path, verbose: false, logLevel: .none, prewarm: false, load: true, download: false)
        let k = try await WhisperKit(config)
        kit = k
        return k
    }

    /// `samples` müssen mono, 16 kHz sein.
    func transcribe(samples: [Float], duration: Double, language: String, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        let kit = try await load()
        var opts = DecodingOptions(task: .transcribe, language: language == "auto" ? nil : language,
                                   temperature: 0, detectLanguage: language == "auto", wordTimestamps: true, chunkingStrategy: .vad)
        opts.skipSpecialTokens = true
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: opts, callback: nil) { segs in
            if let end = segs.last?.end { progress(min(1, Double(end) / max(duration, 1))) }
        }
        let clean = { (s: String) in s.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
        var segments: [SpeechSegment] = []
        for seg in results.flatMap(\.segments) {
            let words = (seg.words ?? []).map { SpokenWord(text: clean($0.word), start: Double($0.start), end: Double($0.end)) }.filter { !$0.text.isEmpty }
            let text = clean(seg.text)
            guard !text.isEmpty else { continue }
            segments.append(SpeechSegment(id: segments.count, start: Double(seg.start), end: Double(seg.end), text: text, words: words))
        }
        return Transcript(segments: segments, language: results.first?.language ?? language)
    }
}
