import Foundation
import AVFoundation
import Vision
import CoreImage

/// Folgt der Hauptperson (Gesicht, sonst Körper) für den automatischen Bildausschnitt.
enum SubjectTracker {
    /// Normierte Bildmitte (0...1, y nach oben) der Person pro Frame, in Sensor-(Puffer-)Koordinaten.
    static func track(asset: AVAsset, progress: @escaping (Double) -> Void) async throws -> [CGPoint] {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let fps = max(1, Double(try await track.load(.nominalFrameRate)))
        let total = try await asset.load(.duration).seconds
        let w = 360
        let h = max(2, Int((Double(w) * Double(natural.height) / Double(natural.width)).rounded()) & ~1)
        let orientation = visionOrientation(transform)
        let inv = inverseOrientationMatrix(transform)

        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        let step = max(1, Int(fps / 8))
        var raw: [CGPoint?] = []
        var cuts: Set<Int> = []
        var prevLuma: Float = -1
        var last: CGPoint?
        var index = 0
        while let sb = out.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let l = meanLuma(pb)
            if prevLuma >= 0, abs(l - prevLuma) > 0.14 { cuts.insert(index); last = nil }
            prevLuma = l
            var found: CGPoint?
            if index % step == 0 || cuts.contains(index) {
                let faces = VNDetectFaceRectanglesRequest()
                let humans = VNDetectHumanRectanglesRequest()
                humans.upperBodyOnly = false
                let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: orientation, options: [:])
                try? handler.perform([faces, humans])
                var cands: [(CGPoint, Double)] = (faces.results ?? []).map { (CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY), Double($0.boundingBox.width * $0.boundingBox.height)) }
                if cands.isEmpty {
                    cands = (humans.results ?? []).map { (CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY), Double($0.boundingBox.width * $0.boundingBox.height) * 0.4) }
                }
                // größte Person, aber der bisherigen treu bleiben, damit der Ausschnitt nicht zwischen Personen springt
                if let best = cands.max(by: { score($0, last) < score($1, last) }) {
                    // Aufrecht-Koordinaten → Sensor-Koordinaten
                    let dx = best.0.x - 0.5, dy = best.0.y - 0.5
                    found = CGPoint(x: 0.5 + inv.a * dx + inv.b * dy, y: 0.5 + inv.c * dx + inv.d * dy)
                    last = found
                }
            }
            raw.append(found)
            index += 1
            if index % 30 == 0 { progress(min(1, Double(index) / max(1, total * fps))) }
        }
        progress(1)
        guard !raw.isEmpty else { return [] }

        // Lücken füllen: halten, am Anfang rückwärts auffüllen
        var xs = [Double](repeating: 0.5, count: raw.count), ys = xs
        var cur: CGPoint?
        for i in 0..<raw.count {
            if cuts.contains(i) { cur = nil }
            if let p = raw[i] { cur = p } else if cur == nil {
                // nächste Detektion innerhalb des Abschnitts suchen
                var j = i
                while j < raw.count, raw[j] == nil, !(j > i && cuts.contains(j)) { j += 1 }
                if j < raw.count, let p = raw[j], !(j > i && cuts.contains(j)) { cur = p }
            }
            if let c = cur { xs[i] = c.x; ys[i] = c.y }
        }
        let radius = max(3, Int(fps * 0.8))
        let sx = MotionPass.smooth(xs, radius: radius, cuts: cuts), sy = MotionPass.smooth(ys, radius: radius, cuts: cuts)
        return (0..<raw.count).map { CGPoint(x: sx[$0], y: sy[$0]) }
    }

    private static func score(_ c: (CGPoint, Double), _ last: CGPoint?) -> Double {
        guard let l = last else { return c.1 }
        return c.1 / (1 + 4 * Double(hypot(c.0.x - l.x, c.0.y - l.y)))
    }

    private static func meanLuma(_ pb: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0, c = 0.0
        for y in stride(from: 0, to: h, by: 4) { for x in stride(from: 0, to: w, by: 4) {
            let p = base + y * bpr + x * 4
            sum += 0.2126 * Double(p[2]) + 0.7152 * Double(p[1]) + 0.0722 * Double(p[0]); c += 1
        } }
        return Float(sum / max(c, 1) / 255)
    }

    static func visionOrientation(_ t: CGAffineTransform) -> CGImagePropertyOrientation {
        func eq(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }
        if eq(t.a, 0) && eq(t.b, 1) && eq(t.c, -1) && eq(t.d, 0) { return .right }
        if eq(t.a, 0) && eq(t.b, -1) && eq(t.c, 1) && eq(t.d, 0) { return .left }
        if eq(t.a, -1) && eq(t.d, -1) { return .down }
        return .up
    }

    /// Inverse der 2×2-Abbildung Sensor→Anzeige (y nach oben), siehe `PlaybackRenderer`: X = a·dx − c·dy, Y = d·dy − b·dx.
    static func inverseOrientationMatrix(_ t: CGAffineTransform) -> (a: Double, b: Double, c: Double, d: Double) {
        let m11 = Double(t.a), m12 = -Double(t.c), m21 = -Double(t.b), m22 = Double(t.d)
        let det = m11 * m22 - m12 * m21
        guard abs(det) > 1e-6 else { return (1, 0, 0, 1) }
        return (m22 / det, -m12 / det, -m21 / det, m11 / det)
    }
}

/// Zuschnitt-Geometrie für Hochformat/Quadrat; berücksichtigt gedrehte Videos (Sensor quer, Anzeige hoch).
struct ReframeGeometry {
    var active = false
    var cropW = 0, cropH = 0       // im Sensor-Format
    var outW = 0, outH = 0

    static func make(natural: CGSize, rotated90: Bool, settings s: VideoSettings) -> ReframeGeometry {
        let W = Int(natural.width), H = Int(natural.height)
        func even(_ v: Double) -> Int { (Int(v.rounded()) + 1) & ~1 }
        guard let a = s.reframe.aspect else {
            return ReframeGeometry(active: false, cropW: W, cropH: H, outW: even(Double(W) * s.upscale), outH: even(Double(H) * s.upscale))
        }
        let rawAspect = rotated90 ? 1 / a : a                    // Breite/Höhe im Sensorformat
        var cw = Double(W), ch = Double(H)
        if rawAspect < Double(W) / Double(H) { cw = Double(H) * rawAspect } else { ch = Double(W) / rawAspect }
        var g = ReframeGeometry(active: true, cropW: min(W, even(cw)), cropH: min(H, even(ch)))
        if s.reframeScaleHD {
            let dispW = 1080.0, dispH = a >= 1 ? 1080.0 / a : 1080.0 / a      // 9:16 → 1080×1920, 4:5 → 1080×1350, 1:1 → 1080×1080
            g.outW = even(rotated90 ? dispH : dispW); g.outH = even(rotated90 ? dispW : dispH)
        } else {
            g.outW = even(Double(g.cropW) * s.upscale); g.outH = even(Double(g.cropH) * s.upscale)
        }
        return g
    }

    func cropRect(center: CGPoint, imageSize: CGSize) -> CGRect {
        let cx = Double(center.x) * Double(imageSize.width), cy = Double(center.y) * Double(imageSize.height)
        let x0 = min(max(0, cx - Double(cropW) / 2), Double(imageSize.width) - Double(cropW))
        let y0 = min(max(0, cy - Double(cropH) / 2), Double(imageSize.height) - Double(cropH))
        return CGRect(x: x0.rounded(), y: y0.rounded(), width: Double(cropW), height: Double(cropH))
    }
}
