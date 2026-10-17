import Foundation
import AVFoundation
import Accelerate
import Vision
import CoreImage

/// Bewegung und Helligkeit pro Frame (Basis für Stabilisierung und Flacker-Korrektur).
struct MotionData {
    var fps: Double
    var analysisWidth: Double
    var lumas: [Float] = []
    /// Verschiebung von Frame k-1 nach Frame k in Analyse-Pixeln (Frame 0 = 0).
    var translations: [CGPoint] = []
    /// Index-Ende der Szenen (Schnitte), für Glättung innerhalb von Szenen.
    var cuts: Set<Int> = []
    var coversWholeAsset = false
    var count: Int { lumas.count }
}

struct VideoAnalysis {
    var width: Int, height: Int
    var fps: Double
    var duration: Double
    var meanLuma: Double
    var p1: Double, p99: Double
    var shadowClip: Double          // Anteil Pixel < 0.04
    var highlightClip: Double       // Anteil Pixel > 0.97
    var meanSaturation: Double
    var neutralRGB: SIMD3<Double>   // Mittel der "fast grauen" Mitteltöne
    var sharpness: Double
    var noiseSigma: Double          // 0...1-Skala (σ/255)
    var faceCount: Int
    var faceLuma: Double?
    var shakePercent: Double        // RMS hochfrequentes Wackeln in % der Bildbreite
    var flickerPercent: Double
    var motion: MotionData?
    /// Verkleinerte Beispielbilder (für Referenzabgleich).
    var samples: [CGImage]
}

enum VideoAnalyzer {
    static func analyze(asset: AVAsset, progress: @escaping (Double, String) -> Void) async throws -> VideoAnalysis {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "VideoToolkit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Keine Videospur gefunden."])
        }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let size = natural.applying(transform)
        let width = Int(abs(size.width).rounded()), height = Int(abs(size.height).rounded())
        let fps = Double(try await track.load(.nominalFrameRate))
        let duration = try await asset.load(.duration).seconds

        // --- Einzelbild-Statistik ---
        progress(0.02, "Bilder auswerten …")
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        gen.maximumSize = CGSize(width: 2560, height: 1440)
        let count = max(6, min(20, Int(duration / 2)))
        var agg = StatsAggregate()
        var samples: [CGImage] = []
        var faceLumas: [Double] = [], faceCount = 0
        for i in 0..<count {
            let t = duration * (0.04 + 0.92 * Double(i) / Double(max(1, count - 1)))
            guard let (cg, _) = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)) else { continue }
            let (s, faces) = frameStats(cg)
            agg.add(s)
            faceCount += faces.count
            faceLumas.append(contentsOf: faces)
            if let small = scaled(cg, width: 640) { samples.append(small) }
            progress(0.02 + 0.4 * Double(i + 1) / Double(count), "Bilder auswerten …")
        }

        // --- Bewegungsdurchlauf (erste 90 s) ---
        progress(0.45, "Bewegung und Helligkeit analysieren …")
        let motion = try await MotionPass.run(asset: asset, maxSeconds: 90) { progress(0.45 + 0.5 * $0, "Bewegung und Helligkeit analysieren …") }

        let shake = MotionPass.shakePercent(motion)
        let flicker = MotionPass.flickerPercent(motion)

        return VideoAnalysis(
            width: width, height: height, fps: fps, duration: duration,
            meanLuma: agg.meanLuma, p1: agg.percentile(0.01), p99: agg.percentile(0.99),
            shadowClip: agg.shadowClip, highlightClip: agg.highlightClip,
            meanSaturation: agg.saturation, neutralRGB: agg.neutral,
            sharpness: agg.sharpness, noiseSigma: agg.noise,
            faceCount: faceCount, faceLuma: faceLumas.isEmpty ? nil : faceLumas.reduce(0, +) / Double(faceLumas.count),
            shakePercent: shake, flickerPercent: flicker, motion: motion, samples: samples)
    }

    // MARK: Einzelbild

    struct FrameStats {
        var hist = [Double](repeating: 0, count: 256)
        var meanLuma = 0.0, shadowClip = 0.0, highlightClip = 0.0, saturation = 0.0
        var neutral = SIMD3<Double>(0, 0, 0), neutralCount = 0.0
        var sharpness = 0.0, noise = 0.0
    }

    struct StatsAggregate {
        var frames: [FrameStats] = []
        mutating func add(_ f: FrameStats) { frames.append(f) }
        private func avg(_ k: KeyPath<FrameStats, Double>) -> Double {
            frames.isEmpty ? 0 : frames.map { $0[keyPath: k] }.reduce(0, +) / Double(frames.count)
        }
        var meanLuma: Double { avg(\.meanLuma) }
        var shadowClip: Double { avg(\.shadowClip) }
        var highlightClip: Double { avg(\.highlightClip) }
        var saturation: Double { avg(\.saturation) }
        var sharpness: Double { frames.isEmpty ? 0 : median(frames.map(\.sharpness)) }
        var noise: Double { frames.isEmpty ? 0 : median(frames.map(\.noise)) }
        var neutral: SIMD3<Double> {
            var s = SIMD3<Double>(0, 0, 0), n = 0.0
            for f in frames { s += f.neutral; n += f.neutralCount }
            if n < 100 { return SIMD3(repeating: meanLuma) }
            return s / n
        }
        func percentile(_ p: Double) -> Double {
            var h = [Double](repeating: 0, count: 256)
            for f in frames { for i in 0..<256 { h[i] += f.hist[i] } }
            let total = h.reduce(0, +)
            guard total > 0 else { return 0 }
            var acc = 0.0
            for i in 0..<256 { acc += h[i]; if acc / total >= p { return Double(i) / 255 } }
            return 1
        }
        private func median(_ v: [Double]) -> Double { let s = v.sorted(); return s[s.count / 2] }
    }

    static func rgba(_ cg: CGImage, width: Int, height: Int) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ok = data.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? data : nil
    }

    static func scaled(_ cg: CGImage, width: Int) -> CGImage? {
        let h = max(1, Int((Double(width) * Double(cg.height) / Double(cg.width)).rounded()))
        guard var data = rgba(cg, width: width, height: h) else { return nil }
        return data.withUnsafeMutableBytes { p in
            CGContext(data: p.baseAddress, width: width, height: h, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    static func luma(rgba d: [UInt8], count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            out[i] = (0.2126 * Float(d[i * 4]) + 0.7152 * Float(d[i * 4 + 1]) + 0.0722 * Float(d[i * 4 + 2])) / 255
        }
        return out
    }

    /// Mittel der unteren Quartils-Blockwerte von |Filter|, Blockgröße b.
    static func blockMeans(_ a: [Float], w: Int, h: Int, block b: Int) -> [Float] {
        var out: [Float] = []
        var by = 0
        while by + b <= h {
            var bx = 0
            while bx + b <= w {
                var sum: Float = 0
                for y in by..<(by + b) {
                    a.withUnsafeBufferPointer { p in
                        var s: Float = 0
                        vDSP_sve(p.baseAddress! + y * w + bx, 1, &s, vDSP_Length(b))
                        sum += s
                    }
                }
                out.append(sum / Float(b * b))
                bx += b
            }
            by += b
        }
        return out
    }

    /// Re-Blur-Test: Wie stark verliert das Bild Detail, wenn man es nochmals weichzeichnet?
    /// Scharfe Bilder verlieren viel (→ Wert nahe 1), bereits unscharfe kaum (→ nahe 0). Inhaltsunabhängig.
    static func reblurSharpness(_ y: [Float], w: Int, h: Int) -> Double {
        let n = w * h
        let lapK: [Float] = [0, 1, 0, 1, -4, 1, 0, 1, 0]
        let gauss: [Float] = [1, 2, 1, 2, 4, 2, 1, 2, 1].map { $0 / 16 }
        var lap = [Float](repeating: 0, count: n)
        vDSP_f3x3(y, vDSP_Length(h), vDSP_Length(w), lapK, &lap)
        vDSP_vabs(lap, 1, &lap, 1, vDSP_Length(n))
        var b1 = [Float](repeating: 0, count: n), b2 = b1
        vDSP_f3x3(y, vDSP_Length(h), vDSP_Length(w), gauss, &b1)
        vDSP_f3x3(b1, vDSP_Length(h), vDSP_Length(w), gauss, &b2)
        var lap2 = [Float](repeating: 0, count: n)
        vDSP_f3x3(b2, vDSP_Length(h), vDSP_Length(w), lapK, &lap2)
        vDSP_vabs(lap2, 1, &lap2, 1, vDSP_Length(n))
        let o = Double(percentile(blockMeans(lap, w: w, h: h, block: 16), 0.9))
        let r = Double(percentile(blockMeans(lap2, w: w, h: h, block: 16), 0.9))
        guard o > 1e-4 else { return 1 }
        return max(0, min(1, 1 - r / o))
    }

    static func frameStats(_ full: CGImage) -> (FrameStats, [Double]) {
        var st = FrameStats()
        // Farb-/Helligkeitsstatistik auf 640 px Breite
        let w = 640, h = max(1, Int((640.0 * Double(full.height) / Double(full.width)).rounded()))
        guard let px = rgba(full, width: w, height: h) else { return (st, []) }
        let n = w * h
        let y = luma(rgba: px, count: n)
        var sumL = 0.0, sat = 0.0
        for i in 0..<n {
            let r = Double(px[i * 4]) / 255, g = Double(px[i * 4 + 1]) / 255, b = Double(px[i * 4 + 2]) / 255
            let mx = max(r, g, b), mn = min(r, g, b)
            let s = mx > 0.02 ? (mx - mn) / mx : 0
            let l = Double(y[i])
            sumL += l; sat += s
            st.hist[min(255, Int(l * 255 + 0.5))] += 1
            if l < 0.04 { st.shadowClip += 1 }
            if l > 0.97 { st.highlightClip += 1 }
            if l > 0.2 && l < 0.85 && s < 0.3 {
                st.neutral += SIMD3(r, g, b); st.neutralCount += 1
            }
        }
        st.meanLuma = sumL / Double(n); st.saturation = sat / Double(n)
        st.shadowClip /= Double(n); st.highlightClip /= Double(n)
        st.hist = st.hist.map { $0 / Double(n) }

        // Rauschen: Immerkaer-Operator auf nativem Mittel-Ausschnitt, flache Blöcke
        let cw = min(full.width, 960), ch = min(full.height, 540)
        if let crop = full.cropping(to: CGRect(x: (full.width - cw) / 2, y: (full.height - ch) / 2, width: cw, height: ch)),
           let cpx = rgba(crop, width: cw, height: ch) {
            let cy = luma(rgba: cpx, count: cw * ch)
            var conv = [Float](repeating: 0, count: cw * ch)
            let nk: [Float] = [1, -2, 1, -2, 4, -2, 1, -2, 1]
            vDSP_f3x3(cy, vDSP_Length(ch), vDSP_Length(cw), nk, &conv)
            vDSP_vabs(conv, 1, &conv, 1, vDSP_Length(cw * ch))
            let nb = blockMeans(conv, w: cw, h: ch, block: 24)
            let m = Double(percentile(nb, 0.2))
            st.noise = (Double.pi / 2).squareRoot() * m / 6
            st.sharpness = reblurSharpness(cy, w: cw, h: ch)
        }

        // Gesichter
        var faceLumas: [Double] = []
        let req = VNDetectFaceRectanglesRequest()
        if let tiny = scaled(full, width: 640) {
            let handler = VNImageRequestHandler(cgImage: tiny, options: [:])
            try? handler.perform([req])
            for f in req.results ?? [] where f.boundingBox.width > 0.05 {
                let bb = f.boundingBox
                let x0 = max(0, Int(bb.minX * Double(w))), x1 = min(w, Int(bb.maxX * Double(w)))
                let y0 = max(0, Int((1 - bb.maxY) * Double(h))), y1 = min(h, Int((1 - bb.minY) * Double(h)))
                guard x1 > x0, y1 > y0 else { continue }
                var s = 0.0, c = 0.0
                for yy in y0..<y1 { for xx in x0..<x1 { s += Double(y[yy * w + xx]); c += 1 } }
                if c > 0 { faceLumas.append(s / c) }
            }
        }
        return (st, faceLumas)
    }
}

// MARK: - Bewegungsdurchlauf

enum MotionPass {
    static let analysisWidth = 480

    static func run(asset: AVAsset, maxSeconds: Double?, progress: @escaping (Double) -> Void) async throws -> MotionData {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return MotionData(fps: 30, analysisWidth: Double(analysisWidth))
        }
        let natural = try await track.load(.naturalSize)
        let fps = max(1, Double(try await track.load(.nominalFrameRate)))
        let total = try await asset.load(.duration).seconds
        let limit = min(maxSeconds ?? total, total)
        let aw = analysisWidth
        let ah = max(2, Int((Double(aw) * Double(natural.height) / Double(natural.width)).rounded()) & ~1)

        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: aw,
            kCVPixelBufferHeightKey as String: ah,
        ])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: limit, preferredTimescale: 600))
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        var data = MotionData(fps: fps, analysisWidth: Double(aw))
        var prevBuffer: CVPixelBuffer?
        var prevLuma: Float = 0
        var index = 0
        while let sb = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let l = meanLuma(pb)
            var t = CGPoint.zero
            if let prev = prevBuffer {
                let cut = abs(l - prevLuma) > 0.14
                let req = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: pb)
                let handler = VNImageRequestHandler(cvPixelBuffer: prev, options: [:])
                if !cut, (try? handler.perform([req])) != nil,
                   let obs = req.results?.first as? VNImageTranslationAlignmentObservation {
                    // alignmentTransform bringt Frame k auf Frame k-1 → Kamerabewegung ist die Inverse
                    let a = obs.alignmentTransform
                    t = CGPoint(x: -a.tx, y: -a.ty)
                    if hypot(t.x, t.y) > Double(aw) * 0.12 { t = .zero; data.cuts.insert(index) }
                } else if cut {
                    data.cuts.insert(index)
                }
            }
            data.lumas.append(l)
            data.translations.append(t)
            prevBuffer = copy(pb)
            prevLuma = l
            index += 1
            if index % 30 == 0 { progress(min(1, Double(index) / (limit * fps))) }
            if Task.isCancelled { reader.cancelReading(); break }
        }
        data.coversWholeAsset = limit >= total - 0.5
        progress(1)
        return data
    }

    /// Reader-Puffer werden recycelt; für den Vorgänger-Frame eine Kopie halten.
    private static func copy(_ src: CVPixelBuffer) -> CVPixelBuffer {
        var dst: CVPixelBuffer?
        CVPixelBufferCreate(nil, CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src),
                            CVPixelBufferGetPixelFormatType(src), nil, &dst)
        guard let d = dst else { return src }
        CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(d, [])
        let h = CVPixelBufferGetHeight(src)
        let sb = CVPixelBufferGetBytesPerRow(src), db = CVPixelBufferGetBytesPerRow(d)
        for y in 0..<h {
            memcpy(CVPixelBufferGetBaseAddress(d)! + y * db, CVPixelBufferGetBaseAddress(src)! + y * sb, min(sb, db))
        }
        CVPixelBufferUnlockBaseAddress(d, []); CVPixelBufferUnlockBaseAddress(src, .readOnly)
        return d
    }

    private static func meanLuma(_ pb: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0, c = 0.0
        for y in stride(from: 0, to: h, by: 3) {
            let row = base + y * bpr
            for x in stride(from: 0, to: w, by: 3) {
                let b = Double(row[x * 4]), g = Double(row[x * 4 + 1]), r = Double(row[x * 4 + 2])
                sum += 0.2126 * r + 0.7152 * g + 0.0722 * b; c += 1
            }
        }
        return Float(sum / max(c, 1) / 255)
    }

    // MARK: Auswertung

    /// Glättet `values` innerhalb von Szenen (Cuts) mit Gauß-Kern, Radius in Frames.
    static func smooth(_ values: [Double], radius: Int, cuts: Set<Int>) -> [Double] {
        let n = values.count
        guard n > 0, radius > 0 else { return values }
        let sigma = Double(radius) / 2
        let kernel = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        var segStart = [Int](repeating: 0, count: n), segEnd = [Int](repeating: n - 1, count: n)
        var s = 0
        for i in 0..<n { if cuts.contains(i) { s = i }; segStart[i] = s }
        var e = n - 1
        for i in stride(from: n - 1, through: 0, by: -1) { segEnd[i] = e; if cuts.contains(i) { e = i - 1 } }
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var acc = 0.0, wsum = 0.0
            for d in -radius...radius {
                let j = i + d
                guard j >= segStart[i], j <= segEnd[i] else { continue }
                let wgt = kernel[d + radius]
                acc += wgt * values[j]; wsum += wgt
            }
            out[i] = wsum > 0 ? acc / wsum : values[i]
        }
        return out
    }

    /// Korrekturversatz pro Frame (Analyse-Pixel), der den Pfad auf die geglättete Bahn legt.
    static func stabilizationOffsets(_ m: MotionData, strength: Double) -> [CGPoint] {
        let n = m.count
        guard n > 2 else { return [CGPoint](repeating: .zero, count: n) }
        var px = [Double](repeating: 0, count: n), py = px
        var ax = 0.0, ay = 0.0
        for i in 0..<n {
            // Bei Schnitten Pfad neu beginnen (Offset 0)
            if m.cuts.contains(i) { ax = 0; ay = 0 } else { ax += Double(m.translations[i].x); ay += Double(m.translations[i].y) }
            px[i] = ax; py[i] = ay
        }
        let radius = max(2, Int(m.fps * (0.25 + 1.75 * strength)))
        let sx = smooth(px, radius: radius, cuts: m.cuts), sy = smooth(py, radius: radius, cuts: m.cuts)
        // Kameraposition p (Bildinhalt wandert -p). Korrektur: Inhalt um (smooth - p) verschieben.
        return (0..<n).map { CGPoint(x: sx[$0] - px[$0], y: sy[$0] - py[$0]) }
    }

    static func shakePercent(_ m: MotionData) -> Double {
        let n = m.count
        guard n > Int(m.fps) * 2 else { return 0 }
        var px = [Double](repeating: 0, count: n), py = px
        var ax = 0.0, ay = 0.0
        for i in 0..<n {
            if m.cuts.contains(i) { ax = 0; ay = 0 } else { ax += Double(m.translations[i].x); ay += Double(m.translations[i].y) }
            px[i] = ax; py[i] = ay
        }
        let r = max(3, Int(m.fps * 0.5))
        let sx = smooth(px, radius: r, cuts: m.cuts), sy = smooth(py, radius: r, cuts: m.cuts)
        var acc = 0.0
        for i in 0..<n { acc += pow(px[i] - sx[i], 2) + pow(py[i] - sy[i], 2) }
        return (acc / Double(n)).squareRoot() / m.analysisWidth * 100
    }

    static func deflickerGains(_ m: MotionData) -> [Float] {
        let n = m.count
        guard n > 4 else { return [Float](repeating: 1, count: n) }
        let l = m.lumas.map(Double.init)
        let s = smooth(l, radius: max(3, Int(m.fps * 0.6)), cuts: m.cuts)
        return (0..<n).map { i in
            guard l[i] > 0.02 else { return 1 }
            return Float(min(1.3, max(0.77, s[i] / l[i])))
        }
    }

    static func flickerPercent(_ m: MotionData) -> Double {
        let n = m.count
        guard n > Int(m.fps) * 2 else { return 0 }
        let g = deflickerGains(m)
        var acc = 0.0, c = 0.0
        for i in 0..<n where !m.cuts.contains(i) { acc += pow(Double(g[i]) - 1, 2); c += 1 }
        return (acc / max(c, 1)).squareRoot() * 100
    }
}
