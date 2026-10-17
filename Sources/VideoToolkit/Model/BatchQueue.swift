import Foundation
import AVFoundation
import AppKit

struct BatchJob: Identifiable {
    enum Status: Equatable { case waiting, working(Double, String), done(URL), failed(String), cancelled }
    let id = UUID()
    let url: URL
    var status: Status = .waiting
}

/// Warteschlange: mehrere Videos nacheinander reparieren und exportieren.
@MainActor
final class BatchQueue: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case auto = "Jede Datei automatisch reparieren"
        case same = "Einstellungen des geöffneten Videos auf alle anwenden"
        var id: String { rawValue }
    }

    @Published var jobs: [BatchJob] = []
    @Published var mode: Mode = .auto
    @Published var outputFolder: URL?
    @Published var applyReference = true
    @Published var options = ExportOptions()
    @Published var running = false
    private var task: Task<Void, Never>?

    func add(_ urls: [URL]) {
        for u in urls where !jobs.contains(where: { $0.url == u }) { jobs.append(BatchJob(url: u)) }
    }
    func remove(_ id: UUID) { jobs.removeAll { $0.id == id } }
    func clearFinished() { jobs.removeAll { if case .done = $0.status { return true }; return false } }

    var doneCount: Int { jobs.filter { if case .done = $0.status { return true }; return false }.count }

    func start(template: Project) {
        guard !running, let folder = outputFolder else { return }
        running = true
        let mode = self.mode, opts = options
        let reference: CGImage? = applyReference ? template.referenceImage : nil
        let refStrength = template.video.referenceStrength > 0 ? template.video.referenceStrength : 0.6
        let tVideo = template.video, tAudio = template.audio, intensity = template.intensity
        task = Task {
            for i in jobs.indices {
                guard !Task.isCancelled else { break }
                if case .done = jobs[i].status { continue }
                let url = jobs[i].url
                jobs[i].status = .working(0, "Analysieren …")
                do {
                    let out = try await process(url: url, folder: folder, mode: mode, options: opts, reference: reference, refStrength: refStrength,
                                                video: tVideo, audio: tAudio, intensity: intensity) { [weak self] p, text in
                        Task { @MainActor in
                            guard let self, i < self.jobs.count, self.jobs[i].url == url else { return }
                            self.jobs[i].status = .working(p, text)
                        }
                    }
                    jobs[i].status = .done(out)
                } catch is CancellationError {
                    jobs[i].status = .cancelled
                } catch {
                    jobs[i].status = .failed(error.localizedDescription)
                }
            }
            running = false
        }
    }

    func cancel() { task?.cancel() }

    private func process(url: URL, folder: URL, mode: Mode, options: ExportOptions, reference: CGImage?, refStrength: Double,
                         video: VideoSettings, audio: AudioSettings, intensity: Double,
                         progress: @escaping (Double, String) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: url)
        var va: VideoAnalysis?, aa: AudioAnalysis?
        if !(try await asset.loadTracks(withMediaType: .video)).isEmpty {
            va = try await VideoAnalyzer.analyze(asset: asset) { p, _ in progress(p * 0.15, "Analysieren …") }
        }
        if let pcm = try await AudioIO.read(asset: asset, duration: 900) { aa = AudioAnalyzer.analyze(pcm) }

        var v: VideoSettings, a: AudioSettings
        switch mode {
        case .auto:
            let enabled = AutoFix.defaultEnabled(video: va.map(Diagnosis.videoIssues) ?? [], audio: aa.map(Diagnosis.audioIssues) ?? [])
            (v, a) = AutoFix.settings(video: va, audio: aa, enabled: enabled, intensity: intensity)
        case .same:
            (v, a) = (video, audio)
        }
        var lut: ColorLUT?
        if let reference, let samples = va?.samples {
            v.referenceStrength = refStrength
            lut = ReferenceMatcher.makeLUT(samples: samples, settings: v, reference: reference, context: FilterChain.makeContext())
        } else if mode == .same { v.referenceStrength = 0 }

        let base = url.deletingPathExtension().lastPathComponent + " – repariert"
        var dest = folder.appendingPathComponent(base).appendingPathExtension("mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) { dest = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension("mp4"); n += 1 }
        try await Exporter.export(asset: asset, video: v, audio: a, noise: aa?.noiseProfile, motion: va?.motion, lut: lut,
                                  options: options, to: dest) { p, text in progress(0.15 + 0.85 * p, text) }
        return dest
    }
}
