import Foundation
import AVFoundation
import AVKit
import CoreImage
import SwiftUI

/// Alles, was der Renderthread pro Frame braucht – threadsicher austauschbar, ohne die Composition neu zu bauen.
final class PreviewState: @unchecked Sendable {
    struct Snapshot {
        var settings = VideoSettings()
        var lut: ColorLUT?
        var sceneRenders: [SceneRender] = []     // leer = Szenen-Modus aus
        var stab: [MotionPass.StabFrame] = []
        var stabZoom: CGFloat = 1
        var gains: [Float] = []
        var fps = 30.0
        var analysisWidth = 480.0
        var analysisHeight = 270.0
        var orientation = CGAffineTransform.identity   // preferredTransform der Videospur
        var compare: CompareMode = .split
        var split: CGFloat = 0.5
        var reframeCenters: [CGPoint] = []         // normierte Bildmitte des Ausschnitts pro Frame (0...1), leer = aus
        var reframeAspect: Double?
    }
    private let lock = NSLock()
    private var snap = Snapshot()
    func update(_ change: (inout Snapshot) -> Void) { lock.lock(); change(&snap); lock.unlock() }
    func get() -> Snapshot { lock.lock(); defer { lock.unlock() }; return snap }
}

enum PlaybackRenderer {
    /// Rechnet die Filterkette für einen Anzeigeframe (vorverkleinert auf Renderbreite).
    static func render(_ source: CIImage, at time: Double, _ snap: PreviewState.Snapshot) -> CIImage {
        let rect = source.extent
        let idx = max(0, Int(time * snap.fps + 0.0001))
        let o = snap.orientation
        let upright = abs(o.b) < 0.01 && abs(o.c) < 0.01          // 0° oder 180° (kein Quer-/Hochformat-Wechsel)
        let rotated90 = !upright
        var settings = snap.settings
        var lut = snap.lut
        if !snap.sceneRenders.isEmpty {
            var si = 0
            for (i, s) in snap.sceneRenders.enumerated() where s.start <= time + 1e-4 { si = i }
            let sc = snap.sceneRenders[si]
            settings = settings.sceneAdjusted(strength: sc.strength, applyMatch: sc.enabled && sc.lut != nil)
            lut = sc.lut
        }
        if rotated90 { settings.rollingShutter = 0; settings.deinterlace = false }   // wirken in Sensor-Zeilenrichtung

        var params = FrameParams()
        if idx < snap.stab.count, settings.stabilize || settings.rollingShutter > 0.001 {
            let f = snap.stab[idx]
            let aw = rotated90 ? snap.analysisHeight : snap.analysisWidth
            let k = Double(rect.width) / aw
            // Vektor aus Sensor-Koordinaten (y nach oben) in Anzeige-Koordinaten (y nach oben) umrechnen
            let dx = f.dx * k, dy = f.dy * k
            let X = Double(o.a) * dx - Double(o.c) * dy
            let Y = Double(o.d) * dy - Double(o.b) * dx
            params.offset = CGPoint(x: X, y: Y)
            let mirrored = (o.a * o.d - o.b * o.c) < 0
            params.rotation = CGFloat(mirrored ? -f.rot : f.rot)
            params.shear = CGFloat(f.shear)
            params.zoom = snap.stabZoom
        }
        if idx < snap.gains.count { params.flickerGain = snap.gains[idx] }

        let before = source
        var img = FilterChain.stage1(source, settings, params)
        img = FilterChain.color(img, settings)
        img = FilterChain.finish(img, settings, lut: lut, scale: 1)
        img = img.cropped(to: rect)
        if settings.reframe.aspect != nil, let a = snap.reframeAspect {
            // Hochformat/Quadrat: Ausschnitt auf die verfolgte Person, zentriert auf schwarzer Fläche
            let W = rect.width, H = rect.height
            var cw = W, ch = H
            if CGFloat(a) < W / H { cw = H * CGFloat(a) } else { ch = W / CGFloat(a) }
            var cx = 0.5, cy = 0.5
            if idx < snap.reframeCenters.count {
                let raw = snap.reframeCenters[idx]
                let dx = Double(raw.x) - 0.5, dy = Double(raw.y) - 0.5
                cx = 0.5 + Double(o.a) * dx - Double(o.c) * dy
                cy = 0.5 + Double(o.d) * dy - Double(o.b) * dx
            }
            let x0 = min(max(0, CGFloat(cx) * W - cw / 2), W - cw), y0 = min(max(0, CGFloat(cy) * H - ch / 2), H - ch)
            let sc = min(W / cw, H / ch)
            let placed = img.cropped(to: CGRect(x: x0, y: y0, width: cw, height: ch))
                .transformed(by: CGAffineTransform(translationX: -x0, y: -y0).concatenating(CGAffineTransform(scaleX: sc, y: sc))
                    .concatenating(CGAffineTransform(translationX: (W - cw * sc) / 2, y: (H - ch * sc) / 2)))
            img = placed.composited(over: CIImage(color: .black).cropped(to: rect))
        }

        switch snap.compare {
        case .after: return img
        case .before: return before
        case .split:
            let mask = CIImage(color: .white).cropped(to: CGRect(x: rect.minX, y: rect.minY, width: rect.width * snap.split, height: rect.height))
            return before.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: mask])
                .cropped(to: rect)
        }
    }
}

@MainActor
final class PlaybackController: ObservableObject {
    let player = AVPlayer()
    let state = PreviewState()
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var audioStatus: String?
    @Published var processedAudioReady = false
    @Published var useProcessedAudio = false { didSet { applyAudioMix() } }

    private let ctx = FilterChain.makeContext()
    private var asset: AVURLAsset?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var origTrack: AVMutableCompositionTrack?, procTrack: AVMutableCompositionTrack?
    private var processedKey: AudioSettings?
    private var processedURL: URL?
    private var audioTask: Task<Void, Never>?
    private var renderWidth: CGFloat = 1280

    var hasVideo = false

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            guard let self else { return }
            MainActor.assumeIsolated { if self.isPlaying { self.currentTime = t.seconds } }
        }
    }

    deinit { if let o = timeObserver { player.removeTimeObserver(o) } }

    /// Lädt das Video in den Player (Composition mit Original- und optional bearbeitetem Ton).
    func load(asset: AVURLAsset, hasVideo: Bool) async {
        self.asset = asset
        self.hasVideo = hasVideo
        processedURL = nil; processedKey = nil; processedAudioReady = false; useProcessedAudio = false
        audioTask?.cancel()
        duration = (try? await asset.load(.duration).seconds) ?? 0
        await rebuildItem(keepingTime: 0, playing: false)
    }

    private func rebuildItem(keepingTime t: Double, playing: Bool) async {
        guard let asset else { return }
        do {
            let comp = AVMutableComposition()
            let dur = try await asset.load(.duration)
            if let vt = try await asset.loadTracks(withMediaType: .video).first,
               let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try ct.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: vt, at: .zero)
                ct.preferredTransform = try await vt.load(.preferredTransform)
            }
            origTrack = nil; procTrack = nil
            if let at = try await asset.loadTracks(withMediaType: .audio).first,
               let ct = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try ct.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: at, at: .zero)
                origTrack = ct
            }
            if let url = processedURL {
                let pa = AVURLAsset(url: url)
                if let at = try await pa.loadTracks(withMediaType: .audio).first,
                   let ct = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try ct.insertTimeRange(CMTimeRange(start: .zero, duration: min(dur, try await pa.load(.duration))), of: at, at: .zero)
                    procTrack = ct
                }
            }
            let item = AVPlayerItem(asset: comp)
            if hasVideo {
                let state = self.state, ctx = self.ctx
                let vc = AVMutableVideoComposition(asset: comp) { request in
                    let snap = state.get()
                    let src = request.sourceImage.cropped(to: request.sourceImage.extent)
                    let out = PlaybackRenderer.render(src, at: request.compositionTime.seconds, snap)
                    request.finish(with: out, context: ctx)
                }
                // Vorschau höchstens in 1280 px Breite rechnen (flüssig auch bei 4K-Material)
                let rs = vc.renderSize
                if rs.width > 1280 { let f = 1280 / rs.width; vc.renderSize = CGSize(width: (rs.width * f).rounded(), height: (rs.height * f).rounded()) }
                item.videoComposition = vc
            }
            player.replaceCurrentItem(with: item)
            applyAudioMix()
            if let o = endObserver { NotificationCenter.default.removeObserver(o) }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isPlaying = false }
            }
            await player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = t
            if playing { player.play(); isPlaying = true } else { isPlaying = false }
        } catch {
            audioStatus = error.localizedDescription
        }
    }

    // MARK: Wiedergabe

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        if currentTime >= duration - 0.05 { seek(to: 0) }
        player.play(); isPlaying = true
    }

    func pause() {
        player.pause(); isPlaying = false
        currentTime = player.currentTime().seconds
    }

    func seek(to t: Double) {
        let target = min(max(0, t), max(0, duration - 0.001))
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(frames: Int, fps: Double) {
        pause()
        seek(to: currentTime + Double(frames) / max(fps, 1))
    }

    /// Nach Änderung der Einstellungen den angehaltenen Frame neu rendern lassen.
    func refreshFrame() {
        guard !isPlaying, player.currentItem != nil else { return }
        let t = player.currentTime()
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Ton

    private func applyAudioMix() {
        guard let item = player.currentItem else { return }
        var params: [AVMutableAudioMixInputParameters] = []
        let showProcessed = useProcessedAudio && procTrack != nil
        if let o = origTrack { let p = AVMutableAudioMixInputParameters(track: o); p.setVolume(showProcessed ? 0 : 1, at: .zero); params.append(p) }
        if let pr = procTrack { let p = AVMutableAudioMixInputParameters(track: pr); p.setVolume(showProcessed ? 1 : 0, at: .zero); params.append(p) }
        let mix = AVMutableAudioMix(); mix.inputParameters = params
        item.audioMix = mix
    }

    /// Berechnet den bearbeiteten Ton für die gesamte Datei (im Hintergrund) und schaltet ihn in der Wiedergabe zu.
    func prepareProcessedAudio(settings: AudioSettings, noise: NoiseProfile?) {
        guard let asset else { return }
        if processedKey == settings, processedURL != nil { return }
        audioTask?.cancel()
        audioStatus = "Ton wird berechnet …"
        audioTask = Task {
            do {
                guard let pcm = try await AudioIO.read(asset: asset) else { audioStatus = nil; return }
                let out = await Task.detached(priority: .userInitiated) { AudioProcessor.process(pcm, settings: settings, noise: noise) }.value
                guard !Task.isCancelled else { return }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("vt-live-\(UUID().uuidString).wav")
                try AudioIO.writeWAV(out, to: url)
                if let old = processedURL { try? FileManager.default.removeItem(at: old) }
                processedURL = url; processedKey = settings
                let wasPlaying = isPlaying
                let t = player.currentTime().seconds
                await rebuildItem(keepingTime: t, playing: wasPlaying)
                processedAudioReady = true
                audioStatus = nil
            } catch { audioStatus = error.localizedDescription }
        }
    }

    func stop() {
        player.pause(); isPlaying = false
        audioTask?.cancel()
        if let u = processedURL { try? FileManager.default.removeItem(at: u) }
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        v.showsFullScreenToggleButton = false
        return v
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) { nsView.player = player }
}
