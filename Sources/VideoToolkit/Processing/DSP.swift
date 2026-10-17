import Foundation
import Accelerate

/// Reelle FFT auf Basis von vDSP. Vorwärts liefert n/2+1 Bins, Rückwärts rekonstruiert exakt (kalibriert).
final class RealFFT {
    let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var re: [Float], im: [Float]
    private var rtScale: Float = 1

    init(size: Int) {
        precondition(size > 4 && (size & (size - 1)) == 0, "FFT-Größe muss Zweierpotenz sein")
        n = size
        log2n = vDSP_Length(log2(Double(size)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        re = [Float](repeating: 0, count: size / 2)
        im = [Float](repeating: 0, count: size / 2)
        // Rundlauf-Skalierung kalibrieren, damit inverse(forward(x)) == x
        let probe = (0..<size).map { Float(sin(Double($0) * 0.37) + 0.3 * cos(Double($0) * 1.9)) }
        var r = [Float](repeating: 0, count: size / 2 + 1), i = r
        forward(probe, re: &r, im: &i)
        var back = [Float](repeating: 0, count: size)
        inverse(re: r, im: i, out: &back)
        var num: Float = 0, den: Float = 0
        vDSP_dotpr(probe, 1, back, 1, &num, vDSP_Length(size))
        vDSP_dotpr(back, 1, back, 1, &den, vDSP_Length(size))
        rtScale = num / max(den, 1e-12)
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    /// input: n Samples (bereits gefenstert). Ausgabe: n/2+1 Bins.
    func forward(_ input: [Float], re outRe: inout [Float], im outIm: inout [Float]) {
        let h = n / 2
        input.withUnsafeBufferPointer { ip in
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { imp in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: imp.baseAddress!)
                    ip.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: h) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(h))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }
        }
        // Gepackt: re[0] = DC, im[0] = Nyquist
        outRe[0] = re[0] * 0.5
        outIm[0] = 0
        outRe[h] = im[0] * 0.5
        outIm[h] = 0
        for k in 1..<h { outRe[k] = re[k] * 0.5; outIm[k] = im[k] * 0.5 }
    }

    func inverse(re inRe: [Float], im inIm: [Float], out: inout [Float]) {
        let h = n / 2
        re[0] = inRe[0] * 2
        im[0] = inRe[h] * 2
        for k in 1..<h { re[k] = inRe[k] * 2; im[k] = inIm[k] * 2 }
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { imp in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: imp.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                out.withUnsafeMutableBufferPointer { op in
                    op.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: h) {
                        vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(h))
                    }
                }
            }
        }
        var s = rtScale
        vDSP_vsmul(out, 1, &s, &out, 1, vDSP_Length(n))
    }
}

// MARK: - Biquad

struct Biquad {
    enum Kind { case highPass, lowPass, notch, peaking, lowShelf, highShelf, bandPass }
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    init() {}
    init(_ kind: Kind, freq: Double, sampleRate: Double, q: Double = 0.7071, gainDB: Double = 0) {
        let f = min(max(freq, 10), sampleRate * 0.49)
        let w0 = 2 * Double.pi * f / sampleRate
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * q)
        let A = pow(10, gainDB / 40)
        var a0 = 1.0
        var nb0 = 1.0, nb1 = 0.0, nb2 = 0.0, na1 = 0.0, na2 = 0.0
        switch kind {
        case .highPass:
            nb0 = (1 + cw) / 2; nb1 = -(1 + cw); nb2 = (1 + cw) / 2
            a0 = 1 + alpha; na1 = -2 * cw; na2 = 1 - alpha
        case .lowPass:
            nb0 = (1 - cw) / 2; nb1 = 1 - cw; nb2 = (1 - cw) / 2
            a0 = 1 + alpha; na1 = -2 * cw; na2 = 1 - alpha
        case .bandPass:
            nb0 = alpha; nb1 = 0; nb2 = -alpha
            a0 = 1 + alpha; na1 = -2 * cw; na2 = 1 - alpha
        case .notch:
            nb0 = 1; nb1 = -2 * cw; nb2 = 1
            a0 = 1 + alpha; na1 = -2 * cw; na2 = 1 - alpha
        case .peaking:
            nb0 = 1 + alpha * A; nb1 = -2 * cw; nb2 = 1 - alpha * A
            a0 = 1 + alpha / A; na1 = -2 * cw; na2 = 1 - alpha / A
        case .lowShelf:
            let s = 2 * sqrt(A) * alpha
            nb0 = A * ((A + 1) - (A - 1) * cw + s)
            nb1 = 2 * A * ((A - 1) - (A + 1) * cw)
            nb2 = A * ((A + 1) - (A - 1) * cw - s)
            a0 = (A + 1) + (A - 1) * cw + s
            na1 = -2 * ((A - 1) + (A + 1) * cw)
            na2 = (A + 1) + (A - 1) * cw - s
        case .highShelf:
            let s = 2 * sqrt(A) * alpha
            nb0 = A * ((A + 1) + (A - 1) * cw + s)
            nb1 = -2 * A * ((A - 1) + (A + 1) * cw)
            nb2 = A * ((A + 1) + (A - 1) * cw - s)
            a0 = (A + 1) - (A - 1) * cw + s
            na1 = 2 * ((A - 1) - (A + 1) * cw)
            na2 = (A + 1) - (A - 1) * cw - s
        }
        b0 = nb0 / a0; b1 = nb1 / a0; b2 = nb2 / a0; a1 = na1 / a0; a2 = na2 / a0
    }

    mutating func process(_ x: inout [Float]) {
        var x1 = self.x1, x2 = self.x2, y1 = self.y1, y2 = self.y2
        let b0 = self.b0, b1 = self.b1, b2 = self.b2, a1 = self.a1, a2 = self.a2
        x.withUnsafeMutableBufferPointer { p in
            for i in 0..<p.count {
                let xi = Double(p[i])
                let y = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = xi; y2 = y1; y1 = y
                p[i] = Float(y)
            }
        }
        self.x1 = x1; self.x2 = x2; self.y1 = y1; self.y2 = y2
    }
}

// MARK: - Utility

@inline(__always) func toDB(_ x: Float) -> Float { 20 * log10(max(x, 1e-9)) }
@inline(__always) func fromDB(_ x: Float) -> Float { pow(10, x / 20) }

func percentile(_ values: [Float], _ p: Double) -> Float {
    guard !values.isEmpty else { return 0 }
    let s = values.sorted()
    let idx = min(s.count - 1, max(0, Int(Double(s.count - 1) * p)))
    return s[idx]
}

/// Gemitteltes Leistungsspektrum (Welch) über gleichmäßig verteilte Segmente.
func welchSpectrum(_ x: [Float], fftSize: Int = 16384, maxSegments: Int = 160) -> [Float] {
    let bins = fftSize / 2 + 1
    var acc = [Float](repeating: 0, count: bins)
    guard x.count >= fftSize else { return acc }
    let fft = RealFFT(size: fftSize)
    var window = [Float](repeating: 0, count: fftSize)
    vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    let maxStart = x.count - fftSize
    let count = min(maxSegments, max(1, maxStart / (fftSize / 2) + 1))
    var re = [Float](repeating: 0, count: bins), im = re, seg = [Float](repeating: 0, count: fftSize)
    for s in 0..<count {
        let start = count == 1 ? 0 : Int(Double(maxStart) * Double(s) / Double(count - 1))
        x.withUnsafeBufferPointer { p in
            vDSP_vmul(p.baseAddress! + start, 1, window, 1, &seg, 1, vDSP_Length(fftSize))
        }
        fft.forward(seg, re: &re, im: &im)
        for k in 0..<bins { acc[k] += re[k] * re[k] + im[k] * im[k] }
    }
    var inv = 1 / Float(count)
    vDSP_vsmul(acc, 1, &inv, &acc, 1, vDSP_Length(bins))
    return acc
}

func bandPower(_ spectrum: [Float], fftSize: Int, sampleRate: Double, from lo: Double, to hi: Double) -> Float {
    let binHz = sampleRate / Double(fftSize)
    let a = max(0, Int(lo / binHz)), b = min(spectrum.count - 1, Int(hi / binHz))
    guard b >= a else { return 0 }
    var sum: Float = 0
    for k in a...b { sum += spectrum[k] }
    return sum
}

/// Integrierte Lautheit (vereinfachtes BS.1770 mit K-Gewichtung und Gating), Kanäle gleich gewichtet.
func integratedLoudness(_ channels: [[Float]], sampleRate: Double) -> Double {
    guard let first = channels.first, first.count > Int(sampleRate * 0.4) else { return -70 }
    var weighted: [[Float]] = []
    for ch in channels {
        var x = ch
        var shelf = Biquad(.highShelf, freq: 1500, sampleRate: sampleRate, q: 0.7071, gainDB: 4)
        var hp = Biquad(.highPass, freq: 38, sampleRate: sampleRate, q: 0.5)
        shelf.process(&x); hp.process(&x)
        weighted.append(x)
    }
    let block = Int(sampleRate * 0.4), hop = Int(sampleRate * 0.1)
    var energies: [Double] = []
    var start = 0
    while start + block <= first.count {
        var e = 0.0
        for x in weighted {
            var ms: Float = 0
            x.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + start, 1, &ms, vDSP_Length(block)) }
            e += Double(ms)
        }
        energies.append(e)
        start += hop
    }
    func lufs(_ e: Double) -> Double { -0.691 + 10 * log10(max(e, 1e-12)) }
    let gate1 = energies.filter { lufs($0) > -70 }
    guard !gate1.isEmpty else { return -70 }
    let rel = lufs(gate1.reduce(0, +) / Double(gate1.count)) - 10
    let gated = gate1.filter { lufs($0) > rel }
    guard !gated.isEmpty else { return lufs(gate1.reduce(0, +) / Double(gate1.count)) }
    return lufs(gated.reduce(0, +) / Double(gated.count))
}
