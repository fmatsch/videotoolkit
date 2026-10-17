import Foundation
import AVFoundation
import CoreVideo

/// Eine erkannte Einstellung (Shot) des Videos.
struct VideoScene: Identifiable {
    let id: Int
    var startFrame: Int
    var start: Double
    var end: Double
    var enabled = true
    var thumbnail: CGImage?
    var samples: [CGImage] = []
    var lut: ColorLUT?
    var duration: Double { end - start }
}

/// Pro-Szene-Angaben für den Export.
struct SceneRender {
    var start: Double
    var enabled: Bool
    var lut: ColorLUT?
    var strength: Double
}

extension VideoSettings {
    /// Im Szenen-Modus ersetzt der Referenzabgleich die globalen Licht-/Farbregler.
    func sceneAdjusted(strength: Double, applyMatch: Bool) -> VideoSettings {
        var s = self
        s.exposure = 0; s.shadows = 0; s.highlights = 0; s.contrast = 1
        s.saturation = 1; s.vibrance = 0; s.temperature = 0; s.tint = 0
        s.referenceStrength = applyMatch ? strength : 0
        return s
    }
}

/// Schnitterkennung: Farbhistogramm- und Pixeldifferenz zwischen aufeinanderfolgenden Frames (verkleinert).
enum SceneDetector {
    struct Result {
        var fps: Double
        var frameTimes: [Double]
        var cutFrames: [Int]       // Index des jeweils ersten Frames einer neuen Szene
    }

    static func detect(asset: AVAsset, sensitivity: Double, progress: @escaping (Double) -> Void) async throws -> Result {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return Result(fps: 30, frameTimes: [], cutFrames: [])
        }
        let natural = try await track.load(.naturalSize)
        let fps = max(1, Double(try await track.load(.nominalFrameRate)))
        let total = try await asset.load(.duration).seconds
        let w = 160
        let h = max(2, Int((Double(w) * Double(natural.height) / Double(natural.width)).rounded()) & ~1)

        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        var times: [Double] = []
        var scores: [Double] = []
        var prevHist: [Float]?, prevThumb: [Float]?
        while let sb = out.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let (hist, thumb) = features(pb)
            if let ph = prevHist, let pt = prevThumb {
                var hd: Float = 0
                for i in 0..<hist.count { hd += abs(hist[i] - ph[i]) }
                hd *= 0.5
                var td: Float = 0
                for i in 0..<thumb.count { td += abs(thumb[i] - pt[i]) }
                td /= Float(thumb.count)
                scores.append(Double(hd) + Double(td) * 1.5)
            } else { scores.append(0) }
            prevHist = hist; prevThumb = thumb
            times.append(CMSampleBufferGetPresentationTimeStamp(sb).seconds)
            if times.count % 60 == 0 { progress(min(1, times[times.count - 1] / max(total, 0.1))) }
        }
        progress(1)

        // Adaptive Schwelle: deutlich über dem lokalen Bewegungsniveau
        let threshold = 0.45 - 0.3 * min(1, max(0, sensitivity))
        let minLen = max(6, Int(fps * 0.4))
        var cuts: [Int] = []
        var last = 0
        for k in 1..<max(1, scores.count) {
            let lo = max(0, k - 10)
            let local = scores[lo..<k].sorted()
            let med = local.isEmpty ? 0 : local[local.count / 2]
            if scores[k] > threshold && scores[k] > 2.5 * max(med, 0.02) && k - last >= minLen {
                cuts.append(k); last = k
            }
        }
        return Result(fps: fps, frameTimes: times, cutFrames: cuts)
    }

    /// 64-Bin-RGB-Histogramm (normiert) und 16×9-Graustufen-Miniatur.
    private static func features(_ pb: CVPixelBuffer) -> ([Float], [Float]) {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        var hist = [Float](repeating: 0, count: 64)
        var thumb = [Float](repeating: 0, count: 16 * 9)
        var tcount = [Float](repeating: 0, count: 16 * 9)
        var n: Float = 0
        for y in 0..<h {
            let row = base + y * bpr
            let ty = min(8, y * 9 / h)
            for x in 0..<w {
                let b = Int(row[x * 4]), g = Int(row[x * 4 + 1]), r = Int(row[x * 4 + 2])
                hist[(r >> 6) << 4 | (g >> 6) << 2 | (b >> 6)] += 1
                n += 1
                let ti = ty * 16 + min(15, x * 16 / w)
                thumb[ti] += (0.2126 * Float(r) + 0.7152 * Float(g) + 0.0722 * Float(b)) / 255
                tcount[ti] += 1
            }
        }
        for i in 0..<64 { hist[i] /= max(n, 1) }
        for i in 0..<thumb.count { thumb[i] /= max(tcount[i], 1) }
        return (hist, thumb)
    }

    /// Szenengrenzen als Szenenliste (ohne Beispielbilder).
    static func scenes(from r: Result, duration: Double) -> [VideoScene] {
        guard !r.frameTimes.isEmpty else { return [VideoScene(id: 0, startFrame: 0, start: 0, end: duration)] }
        let starts = [0] + r.cutFrames
        return starts.enumerated().map { i, f in
            let s = r.frameTimes[min(f, r.frameTimes.count - 1)]
            let e = i + 1 < starts.count ? r.frameTimes[min(starts[i + 1], r.frameTimes.count - 1)] : duration
            return VideoScene(id: i, startFrame: f, start: i == 0 ? 0 : s, end: e)
        }
    }
}
