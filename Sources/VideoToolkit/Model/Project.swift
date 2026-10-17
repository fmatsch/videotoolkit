import Foundation
import AVFoundation
import AppKit
import SwiftUI

enum ProjectState: Equatable {
    case empty
    case analyzing(Double, String)
    case ready
    case exporting(Double, String)
}

enum CompareMode: String, CaseIterable, Identifiable {
    case split = "Geteilt", before = "Vorher", after = "Nachher"
    var id: String { rawValue }
}

@MainActor
final class Project: ObservableObject {
    // Datei
    @Published var url: URL?
    @Published var state: ProjectState = .empty
    @Published var errorMessage: String?
    private(set) var asset: AVURLAsset?

    // Analyse
    @Published var videoAnalysis: VideoAnalysis?
    @Published var audioAnalysis: AudioAnalysis?
    @Published var videoIssues: [Issue] = []
    @Published var audioIssues: [Issue] = []
    @Published var enabledFixes: Set<FixID> = []
    @Published var intensity: Double = 1 { didSet { if oldValue != intensity { reapplyFixes() } } }

    // Einstellungen
    @Published var expertMode = false
    @Published var video = VideoSettings() { didSet { if oldValue != video { videoChanged(old: oldValue) } } }
    @Published var audio = AudioSettings()

    // Referenz
    @Published var referenceImage: CGImage?
    @Published var referenceName: String?
    @Published var referenceBusy = false
    private var lut: ColorLUT?
    private var lutTask: Task<Void, Never>?

    // Vorschau
    @Published var previewTime: Double = 0 { didSet { schedulePreview() } }
    @Published var beforeImage: CGImage?
    @Published var afterImage: CGImage?
    @Published var compare: CompareMode = .split
    @Published var duration: Double = 0
    private var renderer: PreviewRenderer?
    private var currentFrame: (time: Double, image: CGImage)?
    private var previewTask: Task<Void, Never>?
    private var stabCache: (strength: Double, offsets: [CGPoint], zoom: CGFloat)?
    private var gainsCache: [Float]?

    // Audio-Vorschau
    @Published var audioPreviewState: String?
    private var player: AVAudioPlayer?
    private var audioTask: Task<Void, Never>?

    // Export
    @Published var exportOptions = ExportOptions()
    @Published var lastExport: URL?
    private var exportTask: Task<Void, Never>?

    var hasVideo: Bool { videoAnalysis != nil }
    var hasAudio: Bool { audioAnalysis != nil }

    // MARK: Öffnen & Analysieren

    func open(_ url: URL) {
        stopAudio()
        exportTask?.cancel(); previewTask?.cancel(); lutTask?.cancel()
        self.url = url
        errorMessage = nil
        lastExport = nil
        videoAnalysis = nil; audioAnalysis = nil; videoIssues = []; audioIssues = []
        enabledFixes = []; intensity = 1
        video = VideoSettings(); audio = AudioSettings()
        beforeImage = nil; afterImage = nil; currentFrame = nil; stabCache = nil; gainsCache = nil
        let asset = AVURLAsset(url: url)
        self.asset = asset
        state = .analyzing(0, "Datei laden …")
        Task { await analyze(asset) }
    }

    private func analyze(_ asset: AVURLAsset) async {
        do {
            duration = try await asset.load(.duration).seconds
            let hasV = !(try await asset.loadTracks(withMediaType: .video)).isEmpty
            let hasA = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
            guard hasV || hasA else {
                throw NSError(domain: "VideoToolkit", code: 2, userInfo: [NSLocalizedDescriptionKey: "Die Datei enthält weder Video noch Audio."])
            }
            var aa: AudioAnalysis?
            state = .analyzing(0.02, "Audio analysieren …")
            if let pcm = try await AudioIO.read(asset: asset, duration: min(duration, 900)) {
                aa = await Task.detached(priority: .userInitiated) { AudioAnalyzer.analyze(pcm) }.value
            }
            var va: VideoAnalysis?
            if hasV {
                va = try await VideoAnalyzer.analyze(asset: asset) { [weak self] p, text in
                    Task { @MainActor in self?.state = .analyzing(0.1 + 0.9 * p, text) }
                }
            }
            videoAnalysis = va; audioAnalysis = aa
            videoIssues = va.map(Diagnosis.videoIssues) ?? []
            audioIssues = aa.map(Diagnosis.audioIssues) ?? []
            enabledFixes = AutoFix.defaultEnabled(video: videoIssues, audio: audioIssues)
            renderer = hasV ? PreviewRenderer(asset: asset) : nil
            reapplyFixes()
            state = .ready
            previewTime = min(duration * 0.3, max(0, duration - 0.1))
            schedulePreview(immediately: true)
        } catch {
            errorMessage = error.localizedDescription
            state = .empty
            url = nil
        }
    }

    // MARK: Korrekturen

    func isEnabled(_ fix: FixID) -> Bool { enabledFixes.contains(fix) }

    func setFix(_ fix: FixID, enabled: Bool) {
        if enabled { enabledFixes.insert(fix) } else { enabledFixes.remove(fix) }
        applyFix(fix)
    }

    private func applyFix(_ fix: FixID) {
        let on = enabledFixes.contains(fix)
        if fix.isAudio, let aa = audioAnalysis {
            Diagnosis.apply(fix, enabled: on, to: &audio, analysis: aa, intensity: intensity)
        } else if let va = videoAnalysis {
            var v = video
            Diagnosis.apply(fix, enabled: on, to: &v, analysis: va, intensity: intensity)
            video = v
        }
    }

    func reapplyFixes() {
        for issue in videoIssues + audioIssues { applyFix(issue.fix) }
    }

    func setAll(_ on: Bool) {
        let all = Set((videoIssues + audioIssues).map(\.fix))
        enabledFixes = on ? all : []
        reapplyFixes()
    }

    func resetVideo() { let r = video.referenceStrength; video = VideoSettings(); video.referenceStrength = r }
    func resetAudio() { audio = AudioSettings() }

    // MARK: Referenz

    func loadReference(_ url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            errorMessage = "Das Referenzbild konnte nicht geladen werden."
            return
        }
        referenceImage = img
        referenceName = url.lastPathComponent
        if video.referenceStrength == 0 { video.referenceStrength = 0.6 }
        rebuildLUT()
    }

    func clearReference() {
        referenceImage = nil; referenceName = nil; lut = nil
        video.referenceStrength = 0
        schedulePreview()
    }

    private func videoChanged(old: VideoSettings) {
        if referenceImage != nil, old.preReferenceKey != video.preReferenceKey { rebuildLUT() }
        schedulePreview()
    }

    private func rebuildLUT() {
        guard let ref = referenceImage, let va = videoAnalysis, let renderer else { return }
        lutTask?.cancel()
        referenceBusy = true
        let settings = video, samples = va.samples, ctx = renderer.context
        lutTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                ReferenceMatcher.makeLUT(samples: samples, settings: settings, reference: ref, context: ctx)
            }.value
            guard !Task.isCancelled else { return }
            lut = result
            referenceBusy = false
            schedulePreview(immediately: true)
        }
    }

    // MARK: Vorschau

    func schedulePreview(immediately: Bool = false) {
        guard state == .ready || immediately, let renderer else { return }
        previewTask?.cancel()
        let t = previewTime, settings = video, lut = lut
        let params = frameParams(at: t, settings: settings)
        let cached = currentFrame
        previewTask = Task {
            if !immediately { try? await Task.sleep(nanoseconds: 60_000_000) }
            guard !Task.isCancelled else { return }
            var frame: CGImage?
            if let c = cached, abs(c.time - t) < 0.0005 { frame = c.image } else { frame = await renderer.frame(at: t) }
            guard let frame, !Task.isCancelled else { return }
            let scale = CGFloat(frame.width) / CGFloat(videoAnalysis?.width ?? frame.width)
            var p = params
            p.offset = CGPoint(x: p.offset.x * scale, y: p.offset.y * scale)
            let after = await Task.detached(priority: .userInitiated) {
                renderer.render(frame: frame, settings: settings, lut: lut, params: p)
            }.value
            guard !Task.isCancelled else { return }
            currentFrame = (t, frame)
            beforeImage = frame
            afterImage = after
        }
    }

    /// Stabilisierung/Flackern für den Vorschau-Frame (in Pixeln des Originalvideos).
    private func frameParams(at t: Double, settings: VideoSettings) -> FrameParams {
        var p = FrameParams()
        guard let va = videoAnalysis, let m = va.motion, m.count > 0 else { return p }
        let idx = max(0, Int(t * m.fps))
        guard idx < m.count else { return p }   // Analyse deckt nur den Anfang ab; Export rechnet vollständig
        if settings.stabilize {
            if stabCache?.strength != settings.stabilizeStrength {
                let o = MotionPass.stabilizationOffsets(m, strength: settings.stabilizeStrength)
                stabCache = (settings.stabilizeStrength, o,
                             FilterChain.zoomFor(offsets: o, analysisWidth: m.analysisWidth,
                                                 analysisHeight: m.analysisWidth * Double(va.height) / Double(va.width)))
            }
            if let c = stabCache, idx < c.offsets.count {
                let k = Double(va.width) / m.analysisWidth
                p.offset = CGPoint(x: c.offsets[idx].x * k, y: c.offsets[idx].y * k)
                p.zoom = c.zoom
            }
        }
        if settings.deflicker {
            if gainsCache == nil { gainsCache = MotionPass.deflickerGains(m) }
            if let g = gainsCache, idx < g.count { p.flickerGain = g[idx] }
        }
        return p
    }

    // MARK: Audio-Vorschau

    func playAudioPreview(processed: Bool) {
        guard let asset else { return }
        stopAudio()
        let start = max(0, min(previewTime, duration - 12)), settings = audio
        let noise = audioAnalysis?.noiseProfile
        audioPreviewState = "Vorbereiten …"
        audioTask = Task {
            do {
                guard let pcm = try await AudioIO.read(asset: asset, start: start, duration: 12) else {
                    audioPreviewState = nil; return
                }
                let out = processed ? await Task.detached(priority: .userInitiated) {
                    AudioProcessor.process(pcm, settings: settings, noise: noise)
                }.value : pcm
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vt-preview-\(UUID().uuidString).wav")
                try AudioIO.writeWAV(out, to: tmp)
                guard !Task.isCancelled else { return }
                let p = try AVAudioPlayer(contentsOf: tmp)
                player = p
                p.play()
                audioPreviewState = processed ? "Bearbeitet (12 s ab \(Self.format(start)))" : "Original (12 s ab \(Self.format(start)))"
                try? await Task.sleep(nanoseconds: UInt64((p.duration + 0.3) * 1e9))
                if player === p { audioPreviewState = nil }
                try? FileManager.default.removeItem(at: tmp)
            } catch {
                audioPreviewState = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    func stopAudio() {
        audioTask?.cancel(); player?.stop(); player = nil; audioPreviewState = nil
    }

    static func format(_ t: Double) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }

    // MARK: Export

    func export(to dest: URL) {
        guard let asset else { return }
        stopAudio()
        let v = video, a = audio, noise = audioAnalysis?.noiseProfile, motion = videoAnalysis?.motion
        let lut = lut, opts = exportOptions
        state = .exporting(0, "Starten …")
        lastExport = nil
        exportTask = Task {
            do {
                try await Exporter.export(asset: asset, video: v, audio: a, noise: noise, motion: motion, lut: lut,
                                          options: opts, to: dest) { [weak self] p, text in
                    Task { @MainActor in self?.state = .exporting(p, text) }
                }
                lastExport = dest
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            state = .ready
        }
    }

    func cancelExport() { exportTask?.cancel() }
}
