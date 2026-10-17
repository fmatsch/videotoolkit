import Foundation
import AVFoundation
import AppKit
import ImageIO
import Vision
import simd
import CoreImage
import CoreVideo

/// Headless-Modus für Tests und Automatisierung: `VideoToolkit --cli analyze|fix|frame|selftest ...`
enum CLI {
    static func run(_ args: [String]) async -> Int32 {
        guard let cmd = args.first else { print("Befehle: analyze <in> | fix <in> <out> [--no-audio|--no-video] | frame <in> <sek> <png-prefix> | selftest"); return 2 }
        do {
            switch cmd {
            case "stats":
                for path in args.dropFirst() {
                    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
                    let (st, faces) = VideoAnalyzer.frameStats(cg)
                    print(String(format: "%@  schärfe %.4f  rauschen %.4f  luma %.3f  gesichter %d", (path as NSString).lastPathComponent, st.sharpness, st.noise, st.meanLuma, faces.count))
                }
                return 0
            case "dfn":
                guard let pcm = try await AudioIO.read(asset: AVURLAsset(url: URL(fileURLWithPath: args[1]))),
                      let dfn = DeepFilterNet.shared else { print("Modell nicht verfügbar"); return 1 }
                let t0 = Date()
                let out = PCMAudio(channels: try pcm.channels.map { try dfn.enhance($0) }, sampleRate: pcm.sampleRate)
                print(String(format: "DeepFilterNet3: %.1f s Audio in %.2f s", pcm.duration, Date().timeIntervalSince(t0)))
                try AudioIO.writeWAV(out, to: URL(fileURLWithPath: args[2]))
                printAudio(AudioAnalyzer.analyze(pcm)); printAudio(AudioAnalyzer.analyze(out))
                return 0
            case "aiframe":
                let r = PreviewRenderer(asset: AVURLAsset(url: URL(fileURLWithPath: args[1])))
                guard let f = await r.frame(at: 1) else { return 1 }
                var pb: CVPixelBuffer?
                CVPixelBufferCreate(nil, f.width, f.height, kCVPixelFormatType_32BGRA, [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pb)
                r.context.render(CIImage(cgImage: f), to: pb!)
                var t0 = Date()
                let up = try await AIUpscaler.load()
                print(String(format: "Laden: %.1f s", Date().timeIntervalSince(t0)))
                for i in 0..<2 {
                    t0 = Date()
                    let big = try up.upscale4x(pb!)
                    print(String(format: "Frame %d (%dx%d → %dx%d): %.2f s", i, f.width, f.height, CVPixelBufferGetWidth(big), CVPixelBufferGetHeight(big), Date().timeIntervalSince(t0)))
                    if i == 1, let cg = r.context.createCGImage(CIImage(cvPixelBuffer: big), from: CIImage(cvPixelBuffer: big).extent) { save(cg, args[2]) }
                }
                return 0
            case "scenes":
                let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
                let r = try await SceneDetector.detect(asset: asset, sensitivity: Double(args.count > 2 ? args[2] : "0.5") ?? 0.5) { _ in }
                let dur = try await asset.load(.duration).seconds
                for sc in SceneDetector.scenes(from: r, duration: dur) { print(String(format: "Szene %d: %.2f – %.2f s (Frame %d)", sc.id + 1, sc.start, sc.end, sc.startFrame)) }
                return 0
            case "homog":
                // Debug: Translations- vs. Homographie-Registrierung für aufeinanderfolgende Frames
                let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
                let track = try await asset.loadTracks(withMediaType: .video).first!
                let nat = try await track.load(.naturalSize)
                let reader = try AVAssetReader(asset: asset)
                let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 480, kCVPixelBufferHeightKey as String: Int(480 * nat.height / nat.width) & ~1])
                reader.add(out); reader.startReading()
                var prev: CVPixelBuffer?, n = 0
                while let sb = out.copyNextSampleBuffer(), n < 8 {
                    guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                    if let p = prev {
                        let t = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: pb)
                        let h = VNHomographicImageRegistrationRequest(targetedCVPixelBuffer: pb)
                        try VNImageRequestHandler(cvPixelBuffer: p, options: [:]).perform([t, h])
                        let tr = (t.results?.first as? VNImageTranslationAlignmentObservation)?.alignmentTransform
                        let hm = (h.results?.first as? VNImageHomographicAlignmentObservation)?.warpTransform
                        print("frame \(n): trans tx=\(tr?.tx ?? 0) ty=\(tr?.ty ?? 0)")
                        if let m = hm { print("   H cols:", m.columns.0, m.columns.1, m.columns.2) }
                    }
                    prev = copyBuf(pb); n += 1
                }
                return 0
            case "stabdebug":
                let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
                let m = try await MotionPass.run(asset: asset, maxSeconds: nil) { _ in }
                let r = MotionPass.stabilization(m, strength: 0.6, rotation: true, rollingShutter: 2, analysisHeight: 270)
                print("zoom", r.zoom)
                for i in stride(from: 20, to: 60, by: 3) {
                    print(String(format: "k=%d raw t=(%.2f,%.2f) rot=%.4f | corr dx=%.2f dy=%.2f rot=%.4f shear=%.5f", i, m.translations[i].x, m.translations[i].y, m.rotations[i], r.frames[i].dx, r.frames[i].dy, r.frames[i].rot, r.frames[i].shear))
                }
                return 0
            case "shearframe":
                let r = PreviewRenderer(asset: AVURLAsset(url: URL(fileURLWithPath: args[1])))
                guard let f = await r.frame(at: Double(args[2])!) else { return 1 }
                var v = VideoSettings(); v.rollingShutter = 1
                var p = FrameParams(); p.shear = CGFloat(Double(args[3])!)
                if let o = r.render(frame: f, settings: v, lut: nil, params: p) { save(o, args[4]) }
                return 0
            case "audio":
                // audio <in> <out.wav> [declick=0.5 breath=0.6 dereverb=0.7 noise=0.5 ...]
                guard let pcm = try await AudioIO.read(asset: AVURLAsset(url: URL(fileURLWithPath: args[1]))) else { return 1 }
                var a = AudioSettings()
                for kv in args.dropFirst(3) {
                    let p = kv.split(separator: "="); guard p.count == 2, let v = Double(p[1]) else { continue }
                    switch p[0] { case "declick": a.declick = v; case "breath": a.breath = v; case "dereverb": a.dereverb = v
                    case "noise": a.noiseReduction = v; case "voice": a.voiceFocus = v; case "ai": a.aiDenoise = v; default: break }
                }
                let t0 = Date()
                let out = AudioProcessor.process(pcm, settings: a, noise: nil)
                print(String(format: "verarbeitet in %.2f s", Date().timeIntervalSince(t0)))
                try AudioIO.writeWAV(out, to: URL(fileURLWithPath: args[2]))
                return 0
            case "selftest": return SelfTest.run() ? 0 : 1
            case "analyze":
                let (va, aa) = try await analyze(URL(fileURLWithPath: args[1]))
                if let va { printVideo(va) }
                if let aa { printAudio(aa) }
                return 0
            case "fix":
                let input = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[2])
                let asset = AVURLAsset(url: input)
                let (va, aa) = try await analyze(input)
                let vi = va.map(Diagnosis.videoIssues) ?? [], ai = aa.map(Diagnosis.audioIssues) ?? []
                for i in vi + ai { print("• [\(i.severity.label)] \(i.title) – \(i.detail)") }
                let enabled = AutoFix.defaultEnabled(video: vi, audio: ai)
                var (v, a) = AutoFix.settings(video: va, audio: aa, enabled: enabled, intensity: 1)
                if args.contains("--manual") { v = VideoSettings(); a = AudioSettings() }
                if args.contains("--stab") { v.stabilize = true; v.stabilizeRotation = !args.contains("--stab-norot") }
                if let i = args.firstIndex(of: "--lens") { v.lensCorrection = Double(args[i + 1]) ?? 0 }
                if let i = args.firstIndex(of: "--vig") { v.vignetteFix = Double(args[i + 1]) ?? 0 }
                if let i = args.firstIndex(of: "--deband") { v.deband = Double(args[i + 1]) ?? 0 }
                if args.contains("--deint") { v.deinterlace = true }
                if let i = args.firstIndex(of: "--rs") { v.rollingShutter = Double(args[i + 1]) ?? 0 }
                if args.contains("--force-all") {
                    v.denoiseSpatial = 0.6; v.denoiseTemporal = 0.8; v.sharpen = 1; v.upscale = 2; v.aiUpscale = AIModels.upscalerAvailable
                }
                var lut: ColorLUT?
                var sceneRenders: [SceneRender] = [], sceneCuts: Set<Int> = []
                if let si = args.firstIndex(of: "--scene-ref"), let refT = Double(args[si + 1]) {
                    // Szenen-Modus: Referenz = Bild bei refT
                    let r = try await SceneDetector.detect(asset: asset, sensitivity: 0.5) { _ in }
                    let dur = try await asset.load(.duration).seconds
                    var list = SceneDetector.scenes(from: r, duration: dur)
                    let pr = PreviewRenderer(asset: asset)
                    guard let ref = await pr.frame(at: refT) else { return 1 }
                    for i in list.indices {
                        let span = list[i].end - list[i].start
                        for f in [0.2, 0.5, 0.8] {
                            if let cg = await pr.frame(at: list[i].start + max(span * f, 0.1)), let sm = VideoAnalyzer.scaled(cg, width: 640) { list[i].samples.append(sm) }
                        }
                        list[i].lut = ReferenceMatcher.makeLUT(samples: list[i].samples, settings: VideoSettings(), reference: ref, context: pr.context, mode: args.contains("--full") ? .full : .soft)
                    }
                    sceneRenders = list.map { SceneRender(start: $0.start, enabled: true, lut: $0.lut, strength: 0.85) }
                    sceneCuts = Set(r.cutFrames)
                    print("Szenen:", list.count, "Schnitte bei Frames", r.cutFrames)
                }
                if let ri = args.firstIndex(of: "--reference"), let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[ri + 1]) as CFURL, nil),
                   let ref = CGImageSourceCreateImageAtIndex(src, 0, nil), let samples = va?.samples {
                    v.referenceStrength = 0.8
                    lut = ReferenceMatcher.makeLUT(samples: samples, settings: v, reference: ref, context: FilterChain.makeContext())
                    print("Referenz-LUT:", lut != nil)
                }
                print("Video:", v); print("Audio:", a)
                var opts = ExportOptions()
                opts.applyVideo = !args.contains("--no-video"); opts.applyAudio = !args.contains("--no-audio")
                var last = -1
                let t0 = Date()
                try await Exporter.export(asset: asset, video: v, audio: a, noise: aa?.noiseProfile, motion: va?.motion,
                                          lut: lut, options: opts, to: output, scenes: sceneRenders, sceneCuts: sceneCuts) { p, text in
                    let pc = Int(p * 100)
                    if pc != last && pc % 10 == 0 { last = pc; print("  \(pc) % \(text)") }
                }
                print(String(format: "Fertig in %.1f s → %@", Date().timeIntervalSince(t0), output.path))
                return 0
            case "frame":
                let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
                let t = Double(args[2]) ?? 1
                let (va, aa) = try await analyze(URL(fileURLWithPath: args[1]))
                let vi = va.map(Diagnosis.videoIssues) ?? []
                let (v, _) = AutoFix.settings(video: va, audio: aa, enabled: AutoFix.defaultEnabled(video: vi, audio: []), intensity: 1)
                let r = PreviewRenderer(asset: asset)
                guard let f = await r.frame(at: t), let after = r.render(frame: f, settings: v, lut: nil, params: FrameParams()) else { return 1 }
                save(f, args[3] + "-before.png"); save(after, args[3] + "-after.png")
                return 0
            default: print("Unbekannter Befehl"); return 2
            }
        } catch {
            print("Fehler: \(error.localizedDescription)")
            return 1
        }
    }

    static func save(_ cg: CGImage, _ path: String) {
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    static func analyze(_ url: URL) async throws -> (VideoAnalysis?, AudioAnalysis?) {
        let asset = AVURLAsset(url: url)
        var va: VideoAnalysis?, aa: AudioAnalysis?
        if !(try await asset.loadTracks(withMediaType: .video)).isEmpty {
            va = try await VideoAnalyzer.analyze(asset: asset) { _, _ in }
        }
        if let pcm = try await AudioIO.read(asset: asset) { aa = AudioAnalyzer.analyze(pcm) }
        return (va, aa)
    }

    static func printVideo(_ a: VideoAnalysis) {
        print(String(format: "VIDEO %dx%d %.2f fps %.1fs | luma %.3f p1 %.3f p99 %.3f | schatten %.3f lichter %.3f | sat %.3f | neutral %.3f %.3f %.3f | schärfe %.4f | rauschen %.4f | gesichter %d (luma %@) | wackeln %.2f%% kippen %.2f° schwenk %.2f%%/Frame | flackern %.2f%% | vignette %.2f (p75 %.2f) kamm %.2f banding %.2f",
                     a.width, a.height, a.fps, a.duration, a.meanLuma, a.p1, a.p99, a.shadowClip, a.highlightClip, a.meanSaturation,
                     a.neutralRGB.x, a.neutralRGB.y, a.neutralRGB.z, a.sharpness, a.noiseSigma, a.faceCount,
                     a.faceLuma.map { String(format: "%.2f", $0) } ?? "-", a.shakePercent, a.rotShakeDegrees, a.panSpeedPercent, a.flickerPercent, a.vignetteRatio, a.vignetteP75, a.combFraction, a.bandingFraction))
        for i in Diagnosis.videoIssues(a) { print("  • [\(i.severity.label)] \(i.title): \(i.detail)") }
    }
    static func printAudio(_ a: AudioAnalysis) {
        print(String(format: "AUDIO %.1fs | peak %.1f dB clip %.4f%% | %.1f LUFS | floor %.1f speech %.1f snr %.1f | hum %.0f Hz (%.1f dB) | rumble %.1f mud %.1f dull %.1f sib %.1f | dyn %.1f | speech %.2f | klicks/min %.1f | RT60 %@",
                     a.duration, a.peakDB, a.clippedFraction * 100, a.loudnessLUFS, a.noiseFloorDB, a.speechLevelDB, a.snrDB,
                     a.humHz, a.humStrengthDB, a.rumbleDB, a.mudDB, a.dullnessDB, a.sibilanceDB, a.dynamicRangeDB, a.speechFraction, a.clicksPerMinute, a.reverbRT60.map { String(format: "%.3f s", $0) } ?? "-"))
        for i in Diagnosis.audioIssues(a) { print("  • [\(i.severity.label)] \(i.title): \(i.detail)") }
    }
}

func copyBuf(_ src: CVPixelBuffer) -> CVPixelBuffer {
    var dst: CVPixelBuffer?
    CVPixelBufferCreate(nil, CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src), CVPixelBufferGetPixelFormatType(src), nil, &dst)
    CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(dst!, [])
    memcpy(CVPixelBufferGetBaseAddress(dst!)!, CVPixelBufferGetBaseAddress(src)!, CVPixelBufferGetBytesPerRow(src) * CVPixelBufferGetHeight(src))
    CVPixelBufferUnlockBaseAddress(dst!, []); CVPixelBufferUnlockBaseAddress(src, .readOnly)
    return dst!
}
