import Foundation
import CoreImage
import Accelerate

/// Gleicht die Tonwert- und Farbverteilung des Videos an ein Referenzbild an
/// (Histogramm-Matching pro Kanal, dann als 3D-LUT).
enum ReferenceMatcher {
    /// Normalisierte kumulative Verteilung pro Kanal (3 × 256) aus einem Bild.
    static func cdf(of cg: CGImage) -> [[Double]] {
        let w = 320, h = max(1, Int(320.0 * Double(cg.height) / Double(cg.width)))
        guard let px = VideoAnalyzer.rgba(cg, width: w, height: h) else { return [[Double]](repeating: (0..<256).map { Double($0) / 255 }, count: 3) }
        var hist = [[Double]](repeating: [Double](repeating: 0, count: 256), count: 3)
        for i in 0..<(w * h) { for c in 0..<3 { hist[c][Int(px[i * 4 + c])] += 1 } }
        return hist.map { h in
            var acc = 0.0
            let total = h.reduce(0, +)
            return h.map { acc += $0; return acc / max(total, 1) }
        }
    }

    static func average(_ cdfs: [[[Double]]]) -> [[Double]] {
        var out = [[Double]](repeating: [Double](repeating: 0, count: 256), count: 3)
        for c in cdfs { for ch in 0..<3 { for i in 0..<256 { out[ch][i] += c[ch][i] / Double(cdfs.count) } } }
        return out
    }

    /// Kurven, die die Quellverteilung auf die Referenzverteilung abbilden.
    static func match(source: [[Double]], reference: [[Double]]) -> [[Float]] {
        var curves: [[Float]] = []
        for c in 0..<3 {
            var map = [Float](repeating: 0, count: 256)
            var j = 0
            for i in 0..<256 {
                let target = source[c][i]
                while j < 255 && reference[c][j] < target { j += 1 }
                map[i] = Float(j) / 255
            }
            // glätten (gleitender Mittelwert), monoton halten
            var sm = map
            let r = 6
            for i in 0..<256 {
                var s: Float = 0, n: Float = 0
                for d in -r...r { let k = i + d; if k >= 0 && k < 256 { s += map[k]; n += 1 } }
                sm[i] = s / n
            }
            for i in 1..<256 { sm[i] = max(sm[i], sm[i - 1]) }
            curves.append(sm)
        }
        return curves
    }

    /// Erzeugt das LUT, indem die Beispielbilder durch die Vor-Referenz-Kette geschickt werden.
    static func makeLUT(samples: [CGImage], settings: VideoSettings, reference: CGImage, context: CIContext) -> ColorLUT? {
        guard !samples.isEmpty else { return nil }
        var pre = settings
        pre.referenceStrength = 0
        var cdfs: [[[Double]]] = []
        for s in samples {
            let ci = FilterChain.color(CIImage(cgImage: s), pre)
            guard let out = context.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: FilterChain.colorSpace) else { continue }
            cdfs.append(cdf(of: out))
        }
        guard !cdfs.isEmpty else { return nil }
        let src = average(cdfs)
        let ref = cdf(of: reference)
        return ColorLUT(curves: match(source: src, reference: ref))
    }
}
