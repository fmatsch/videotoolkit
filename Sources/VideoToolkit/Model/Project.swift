import Foundation
import AVFoundation
import AppKit
import SwiftUI
import Combine

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
    private var videoOrientation = CGAffineTransform.identity

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
    @Published var audio = AudioSettings() { didSet { if oldValue != audio { audioChanged() } } }
    private var liveAudioTask: Task<Void, Never>?

    // Referenz
    @Published var referenceImage: CGImage?
    @Published var referenceName: String?
    @Published var referenceBusy = false
    private var lut: ColorLUT?
    private var lutTask: Task<Void, Never>?

    // Sprache: Transkription (Whisper), Pausenschnitt, Untertitel
    @Published var speech = SpeechSettings() { didSet { updateRemoved() } }
    @Published var transcript: Transcript?
    @Published var transcribing: (Double, String)?
    @Published var removedRanges: [TimeRange] = []
    @Published var cues: [Cue] = []
    private let transcriber = Transcriber()
    private var transcribeTask: Task<Void, Never>?
    var removedSeconds: Double { removedRanges.reduce(0) { $0 + $1.length } }

    // Szenen-Modus: Schnitterkennung → Szenen einzeln an ein Referenzbild angleichen → wieder zusammensetzen
    @Published var sceneMode = false {
        didSet { if sceneMode && scenes.isEmpty && sceneProgress == nil { detectScenes() } else { schedulePreview() } }
    }
    @Published var scenes: [VideoScene] = [] { didSet { schedulePreview() } }
    @Published var sceneSensitivity = 0.5
    @Published var sceneReference: CGImage?
    @Published var sceneReferenceLabel: String?
    @Published var sceneReferenceSceneID: Int?
    @Published var sceneMatchStrength = 0.85 { didSet { schedulePreview() } }
    @Published var sceneMatchMode: MatchMode = .full { didSet { if oldValue != sceneMatchMode { rebuildSceneLUTs() } } }
    @Published var sceneProgress: (Double, String)?
    private var sceneCutFrames: Set<Int> = []
    private var sceneTask: Task<Void, Never>?
    private var sceneLUTTask: Task<Void, Never>?

    // Vorschau
    @Published var previewTime: Double = 0
    @Published var compare: CompareMode = .split { didSet { schedulePreview() } }
    @Published var splitFraction: CGFloat = 0.5 { didSet { schedulePreview() } }
    let playback = PlaybackController()
    let batch = BatchQueue()
    private var playbackSink: AnyCancellable?
    private var fullMotionTask: Task<Void, Never>?
    private var reframeCenters: [CGPoint] = []
    private var trackingTask: Task<Void, Never>?
    @Published var duration: Double = 0
    private var renderer: PreviewRenderer?
    private var stabCache: (key: [Double], frames: [MotionPass.StabFrame], zoom: CGFloat)?
    private var gainsCache: [Float]?

    // Audio-Vorschau
    @Published var audioPreviewState: String?
    private var player: AVAudioPlayer?
    private var audioTask: Task<Void, Never>?

    // Export
    @Published var exportOptions = ExportOptions()
    @Published var lastExport: URL?
    private var exportTask: Task<Void, Never>?

    init() {
        playbackSink = playback.$currentTime.sink { [weak self] t in self?.previewTime = t }
    }

    var hasVideo: Bool { videoAnalysis != nil }
    var hasAudio: Bool { audioAnalysis != nil }

    // MARK: Öffnen & Analysieren

    func open(_ url: URL) {
        stopAudio()
        exportTask?.cancel(); transcribeTask?.cancel(); transcript = nil; transcribing = nil; removedRanges = []; cues = []; speech = SpeechSettings(); fullMotionTask?.cancel(); trackingTask?.cancel(); reframeCenters = []; trackingTask = nil; playback.stop(); lutTask?.cancel(); sceneTask?.cancel(); sceneLUTTask?.cancel()
        sceneMode = false; scenes = []; sceneReference = nil; sceneReferenceLabel = nil; sceneReferenceSceneID = nil
        sceneProgress = nil; sceneCutFrames = []
        self.url = url
        errorMessage = nil
        lastExport = nil
        videoAnalysis = nil; audioAnalysis = nil; videoIssues = []; audioIssues = []
        enabledFixes = []; intensity = 1
        video = VideoSettings(); audio = AudioSettings()
        stabCache = nil; gainsCache = nil
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
            if let vt = try await asset.loadTracks(withMediaType: .video).first { videoOrientation = try await vt.load(.preferredTransform) }
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
            await playback.load(asset: asset, hasVideo: hasV)
            if hasV { playback.seek(to: min(duration * 0.3, max(0, duration - 0.1))) }
            schedulePreview()
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

    // MARK: Sprache

    func transcribe() {
        guard let asset, hasAudio else { return }
        guard Transcriber.isAvailable else { errorMessage = "Das Whisper-Modell fehlt. Lade es mit Scripts/fetch_models.sh whisper oder importiere es im Tab „Sprache“."; return }
        transcribeTask?.cancel()
        transcribing = (0, "Audio vorbereiten …")
        let lang = speech.language, dur = duration
        transcribeTask = Task {
            do {
                guard let pcm = try await AudioIO.read(asset: asset) else { transcribing = nil; return }
                let samples = await Task.detached(priority: .userInitiated) { Resampler.resample(pcm.mono, from: pcm.sampleRate, to: 16_000) }.value
                transcribing = (0.02, "Modell wird geladen (beim ersten Mal dauert das einige Minuten) …")
                let t = try await transcriber.transcribe(samples: samples, duration: dur, language: lang) { [weak self] p in
                    Task { @MainActor in self?.transcribing = (0.05 + 0.95 * p, "Sprache wird erkannt …") }
                }
                guard !Task.isCancelled else { return }
                transcript = t
                cues = SpeechEditor.cues(from: t)
                updateRemoved()
                transcribing = nil
            } catch is CancellationError {
                transcribing = nil
            } catch {
                transcribing = nil
                errorMessage = "Transkription fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }

    func cancelTranscribe() { transcribeTask?.cancel(); transcribing = nil }

    /// Entfernte Bereiche (Pausen, Füllwörter) aus Transkript und Einstellungen berechnen.
    func updateRemoved() {
        guard let t = transcript else { removedRanges = []; return }
        let s = speech, dur = duration
        removedRanges = SpeechEditor.removedRanges(t, settings: s, duration: dur, mono: nil, sampleRate: 48_000)
    }

    func exportSRT(to url: URL) {
        let text = SpeechEditor.srt(cues, removed: removedRanges)
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { errorMessage = error.localizedDescription }
    }

    // MARK: Szenen

    func sceneIndex(at time: Double) -> Int? {
        guard !scenes.isEmpty else { return nil }
        return scenes.lastIndex { $0.start <= time + 1e-4 } ?? 0
    }

    func detectScenes() {
        guard let asset, hasVideo, let renderer else { return }
        sceneTask?.cancel()
        sceneProgress = (0, "Schnitte suchen …")
        let sens = sceneSensitivity, dur = duration
        sceneTask = Task {
            do {
                let r = try await SceneDetector.detect(asset: asset, sensitivity: sens) { [weak self] p in
                    Task { @MainActor in self?.sceneProgress = (p * 0.5, "Schnitte suchen …") }
                }
                var list = SceneDetector.scenes(from: r, duration: dur)
                for i in list.indices {
                    try Task.checkCancellation()
                    let sc = list[i], span = max(sc.end - sc.start, 0.05)
                    var imgs: [CGImage] = []
                    for f in [0.2, 0.5, 0.8] {
                        let t = min(max(sc.start + max(span * f, 0.1), sc.start), max(sc.start, dur - 0.05))
                        if let cg = await renderer.frame(at: t), let small = VideoAnalyzer.scaled(cg, width: 640) { imgs.append(small) }
                    }
                    list[i].samples = imgs
                    list[i].thumbnail = imgs.count > 1 ? VideoAnalyzer.scaled(imgs[1], width: 200) : imgs.first.flatMap { VideoAnalyzer.scaled($0, width: 200) }
                    sceneProgress = (0.5 + 0.5 * Double(i + 1) / Double(list.count), "Szenen vorbereiten …")
                }
                sceneCutFrames = Set(r.cutFrames)
                videoAnalysis?.motion?.cuts.formUnion(sceneCutFrames)
                stabCache = nil; gainsCache = nil
                scenes = list
                sceneProgress = nil
                rebuildSceneLUTs()
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
                sceneProgress = nil
            }
        }
    }

    /// Das aktuell angezeigte Bild als Referenz für alle Szenen verwenden.
    func useCurrentFrameAsSceneReference() {
        guard let renderer else { return }
        let t = previewTime
        Task {
            guard let frame = await renderer.frame(at: t) else { return }
            sceneReference = frame
            sceneReferenceLabel = "Bild bei \(Project.format(t))"
            sceneReferenceSceneID = sceneIndex(at: t)
            rebuildSceneLUTs()
        }
    }

    func useImageFileAsSceneReference(_ url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            errorMessage = "Das Referenzbild konnte nicht geladen werden."; return
        }
        sceneReference = img
        sceneReferenceLabel = url.lastPathComponent
        sceneReferenceSceneID = nil
        rebuildSceneLUTs()
    }

    func rebuildSceneLUTs() {
        guard let ref = sceneReference, let renderer, !scenes.isEmpty else { return }
        sceneLUTTask?.cancel()
        sceneProgress = (0, "Szenen angleichen …")
        let list = scenes, mode = sceneMatchMode, ctx = renderer.context
        sceneLUTTask = Task {
            let luts: [ColorLUT?] = await Task.detached(priority: .userInitiated) {
                list.map { ReferenceMatcher.makeLUT(samples: $0.samples, settings: VideoSettings(), reference: ref, context: ctx, mode: mode) }
            }.value
            guard !Task.isCancelled, luts.count == scenes.count else { return }
            var updated = scenes
            for i in updated.indices { updated[i].lut = luts[i] }
            scenes = updated
            sceneProgress = nil
        }
    }

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
        ensureTracking()
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
            schedulePreview()
        }
    }

    // MARK: Vorschau

    /// Aktuelle Einstellungen an den Player übergeben; der angehaltene Frame wird neu gerendert.
    func schedulePreview() {
        guard let va = videoAnalysis else { return }
        ensureFullMotion()
        var stab: [MotionPass.StabFrame] = [], zoom: CGFloat = 1, gains: [Float] = []
        if let m = va.motion, m.count > 0 {
            if video.stabilize || video.rollingShutter > 0.001 {
                let key = [video.stabilizeStrength, video.stabilize ? 1 : 0, video.stabilizeRotation ? 1 : 0, video.rollingShutter, Double(m.count), Double(m.cuts.count)]
                if stabCache?.key != key {
                    let r = MotionPass.stabilization(m, strength: video.stabilizeStrength, translate: video.stabilize,
                                                     rotation: video.stabilizeRotation, rollingShutter: video.rollingShutter,
                                                     analysisHeight: m.analysisWidth * Double(va.height) / Double(va.width))
                    stabCache = (key, r.frames, r.zoom)
                }
                if let c = stabCache { stab = c.frames; zoom = c.zoom }
            }
            if video.deflicker {
                if gainsCache == nil || gainsCache?.count != m.count { gainsCache = MotionPass.deflickerGains(m) }
                gains = gainsCache ?? []
            }
        }
        let renders: [SceneRender] = (sceneMode && sceneReference != nil)
            ? scenes.map { SceneRender(start: $0.start, enabled: $0.enabled, lut: $0.lut, strength: sceneMatchStrength) } : []
        let (v, l, cmp, spl) = (video, lut, compare, splitFraction)
        let fps = va.motion?.fps ?? va.fps, aw = va.motion?.analysisWidth ?? 480
        let ah = aw * Double(va.height) / Double(va.width)
        let orient = videoOrientation
        let centers = reframeCenters, aspect = video.reframe.aspect
        playback.state.update {
            $0.reframeCenters = centers; $0.reframeAspect = aspect
            $0.settings = v; $0.lut = l; $0.sceneRenders = renders
            $0.stab = stab; $0.stabZoom = zoom; $0.gains = gains
            $0.fps = fps; $0.analysisWidth = aw; $0.analysisHeight = ah
            $0.orientation = orient; $0.compare = cmp; $0.split = spl
        }
        playback.refreshFrame()
    }

    /// Hochformat-/Quadrat-Ausschnitt: Person über das ganze Video verfolgen (einmalig, im Hintergrund).
    private func ensureTracking() {
        guard let asset, video.reframe != .none, reframeCenters.isEmpty, trackingTask == nil else { return }
        playback.audioStatus = "Person wird verfolgt …"
        trackingTask = Task {
            if let c = try? await SubjectTracker.track(asset: asset, progress: { [weak self] p in
                Task { @MainActor in self?.playback.audioStatus = String(format: "Person wird verfolgt … %.0f %%", p * 100) }
            }) { reframeCenters = c }
            playback.audioStatus = nil
            trackingTask = nil
            schedulePreview()
        }
    }

    /// Stabilisierung/Flackern brauchen die Bewegungsdaten des ganzen Videos (Analyse deckt zunächst nur 90 s ab).
    private func ensureFullMotion() {
        guard let asset, let m = videoAnalysis?.motion, !m.coversWholeAsset, fullMotionTask == nil,
              video.stabilize || video.deflicker || video.rollingShutter > 0.001 else { return }
        playback.audioStatus = "Bewegung im ganzen Video analysieren …"
        fullMotionTask = Task {
            let cuts = sceneCutFrames
            if var full = try? await MotionPass.run(asset: asset, maxSeconds: nil, progress: { _ in }) {
                full.cuts.formUnion(cuts)
                videoAnalysis?.motion = full
                stabCache = nil; gainsCache = nil
            }
            playback.audioStatus = nil
            fullMotionTask = nil
            schedulePreview()
        }
    }

    func seek(to t: Double) { playback.seek(to: t) }

    // MARK: Ton in der Wiedergabe

    private func audioChanged() {
        guard playback.useProcessedAudio else { return }
        liveAudioTask?.cancel()
        liveAudioTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            playback.prepareProcessedAudio(settings: audio, noise: audioAnalysis?.noiseProfile)
        }
    }

    /// Schaltet den bearbeiteten Ton in der Wiedergabe ein/aus (rechnet ihn beim ersten Mal im Hintergrund).
    func setLiveProcessedAudio(_ on: Bool) {
        if on {
            playback.prepareProcessedAudio(settings: audio, noise: audioAnalysis?.noiseProfile)
            playback.useProcessedAudio = true
        } else {
            playback.useProcessedAudio = false
        }
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
                await AIModels.prepare(audio: settings)
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
        let renders: [SceneRender] = (sceneMode && sceneReference != nil)
            ? scenes.map { SceneRender(start: $0.start, enabled: $0.enabled, lut: $0.lut, strength: sceneMatchStrength) } : []
        let cuts = sceneMode ? sceneCutFrames : []
        let centers = reframeCenters
        let removed = removedRanges
        let burnCues = speech.burnSubtitles ? cues : []
        let scale = speech.subtitleScale
        state = .exporting(0, "Starten …")
        lastExport = nil
        exportTask = Task {
            do {
                try await Exporter.export(asset: asset, video: v, audio: a, noise: noise, motion: motion, lut: lut,
                                          options: opts, to: dest, scenes: renders, sceneCuts: cuts, reframeCenters: centers,
                                          removed: removed, cues: burnCues, subtitleScale: scale) { [weak self] p, text in
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
