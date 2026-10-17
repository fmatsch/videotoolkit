import Foundation
import CoreML
import Accelerate

/// Quellentrennung mit HTDemucs (ft, "fused" Core-ML-Paket): Stimme (vocals) vom Rest trennen.
/// Das Netz bekommt Zeitsignal + Spektrogramm (complex-as-channels); STFT/iSTFT, Segmentierung und Überblendung
/// erledigt dieser Code nach dem Ablauf von Demucs (`_spec`/`_ispec` in htdemucs.py).
final class DemucsSeparator: @unchecked Sendable {
    static let segmentLength = 343_980          // 7,8 s bei 44,1 kHz
    static let stride = 257_985                 // 25 % Überlappung
    static let sampleRate = 44_100.0
    static let nfft = 4096, hop = 1024, bins = 2048, frames = 336

    nonisolated(unsafe) static var shared: DemucsSeparator?
    static var isAvailable: Bool { ModelLocator.url("Optional/htdemucs-ft-fused/htdemucs_ft_fused.mlpackage") != nil }

    /// Kompiliert das Modell beim ersten Mal (wird zwischengespeichert) und macht es für `AudioProcessor` verfügbar.
    static func prepare() async throws {
        if shared != nil { return }
        guard let pkg = ModelLocator.url("Optional/htdemucs-ft-fused/htdemucs_ft_fused.mlpackage"),
              let support = ModelLocator.supportDirectory else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let compiled = support.appendingPathComponent("htdemucs_ft_fused.mlmodelc")
        if !FileManager.default.fileExists(atPath: compiled.path) {
            let tmp = try await MLModel.compileModel(at: pkg)
            try? FileManager.default.removeItem(at: compiled)
            try FileManager.default.moveItem(at: tmp, to: compiled)
        }
        let cfg = MLModelConfiguration(); cfg.computeUnits = .cpuAndGPU
        shared = DemucsSeparator(model: try MLModel(contentsOf: compiled, configuration: cfg))
    }

    private let model: MLModel
    private let fft = RealFFT(size: nfft)
    private let window: [Float] = (0..<nfft).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(nfft))) }
    private init(model: MLModel) { self.model = model }

    struct Stems { var vocals: [[Float]]; var rest: [[Float]] }

    /// stereo: 2 Kanäle bei 44,1 kHz. Gibt Stimme und Rest (Schlagzeug+Bass+Sonstiges) zurück.
    func separate(stereo: [[Float]], progress: ((Double) -> Void)? = nil) throws -> Stems {
        let T = Self.segmentLength, n = stereo[0].count
        var vocals = [[Float]](repeating: [Float](repeating: 0, count: n), count: 2)
        var rest = vocals
        var weightSum = [Float](repeating: 0, count: n)
        let tri = (0..<T).map { Float(min($0 + 1, T - $0)) }
        var start = 0
        while true {
            let len = min(T, n - start)
            if len <= 0 { break }
            var seg = [[Float]](repeating: [Float](repeating: 0, count: T), count: 2)
            for c in 0..<2 { seg[c].replaceSubrange(0..<len, with: stereo[c][start..<(start + len)]) }
            let (v, r) = try process(segment: seg)
            for c in 0..<2 {
                for i in 0..<len {
                    let w = tri[i] * (start > 0 || i >= 0 ? 1 : 1)
                    vocals[c][start + i] += v[c][i] * w
                    rest[c][start + i] += r[c][i] * w
                }
            }
            for i in 0..<len { weightSum[start + i] += tri[i] }
            progress?(Double(min(n, start + T)) / Double(n))
            if start + T >= n { break }
            start += Self.stride
        }
        for c in 0..<2 { for i in 0..<n { let w = max(weightSum[i], 1e-6); vocals[c][i] /= w; rest[c][i] /= w } }
        return Stems(vocals: vocals, rest: rest)
    }

    // MARK: Ein Segment

    private func process(segment x: [[Float]]) throws -> ([[Float]], [[Float]]) {
        let T = Self.segmentLength, F = Self.bins, L = Self.frames
        // Normalisierung über Mono-Mittel des Segments (wie apply_model)
        var ref = [Float](repeating: 0, count: T)
        for i in 0..<T { ref[i] = 0.5 * (x[0][i] + x[1][i]) }
        var mean: Float = 0, std: Float = 0
        vDSP_normalize(ref, 1, nil, 1, &mean, &std, vDSP_Length(T))
        std = max(std, 1e-6)
        var xn = x
        for c in 0..<2 { for i in 0..<T { xn[c][i] = (x[c][i] - mean) / std } }

        let mix = try MLMultiArray(shape: [1, 2, NSNumber(value: T)], dataType: .float32)
        let mp = mix.dataPointer.assumingMemoryBound(to: Float.self)
        for c in 0..<2 { xn[c].withUnsafeBufferPointer { (mp + c * T).update(from: $0.baseAddress!, count: T) } }
        let z = try MLMultiArray(shape: [1, 4, NSNumber(value: F), NSNumber(value: L)], dataType: .float32)
        let zp = z.dataPointer.assumingMemoryBound(to: Float.self)
        for c in 0..<2 {
            let (re, im) = spec(xn[c])
            re.withUnsafeBufferPointer { (zp + (2 * c) * F * L).update(from: $0.baseAddress!, count: F * L) }
            im.withUnsafeBufferPointer { (zp + (2 * c + 1) * F * L).update(from: $0.baseAddress!, count: F * L) }
        }
        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mix": MLFeatureValue(multiArray: mix), "z_cac": MLFeatureValue(multiArray: z)]))
        guard let tOut = out.featureValue(for: "time_out")?.multiArrayValue, let zOut = out.featureValue(for: "zout_cac")?.multiArrayValue else {
            throw CocoaError(.coderValueNotFound)
        }
        // Stem-Reihenfolge: drums, bass, other, vocals
        let timeFlat = DeepFilterNet.flatten(tOut, count: 4 * 2 * T)          // [4][2][T]
        let zFlat = DeepFilterNet.flatten(zOut, count: 4 * 4 * F * L)         // [4][4][F][L]
        var vocals = [[Float]](repeating: [], count: 2), rest = vocals
        for c in 0..<2 {
            // Stimme
            let vRe = Array(zFlat[((3 * 4 + 2 * c) * F * L)..<((3 * 4 + 2 * c + 1) * F * L)])
            let vIm = Array(zFlat[((3 * 4 + 2 * c + 1) * F * L)..<((3 * 4 + 2 * c + 2) * F * L)])
            var v = ispec(re: vRe, im: vIm)
            let vt = timeFlat[((3 * 2 + c) * T)..<((3 * 2 + c + 1) * T)]
            for i in 0..<T { v[i] += vt[vt.startIndex + i] }
            // Rest: Spektren der drei anderen Stems summieren (linear), dann ein iSTFT
            var rRe = [Float](repeating: 0, count: F * L), rIm = rRe
            for s in 0..<3 {
                let o = (s * 4 + 2 * c) * F * L, o2 = (s * 4 + 2 * c + 1) * F * L
                for i in 0..<(F * L) { rRe[i] += zFlat[o + i]; rIm[i] += zFlat[o2 + i] }
            }
            var r = ispec(re: rRe, im: rIm)
            for s in 0..<3 {
                let o = (s * 2 + c) * T
                for i in 0..<T { r[i] += timeFlat[o + i] }
            }
            // Zurück auf den ursprünglichen Pegel
            for i in 0..<T { v[i] = v[i] * std + mean; r[i] = r[i] * std + 0 }
            vocals[c] = v; rest[c] = r
        }
        return (vocals, rest)
    }

    // MARK: STFT / iSTFT (nach demucs/htdemucs.py)

    /// Gibt Real- und Imaginärteil als [bin][frame] (F×L, zeilenweise) zurück.
    private func spec(_ x: [Float]) -> ([Float], [Float]) {
        let T = Self.segmentLength, hl = Self.hop, N = Self.nfft, F = Self.bins, L = Self.frames
        let le = Int((Double(T) / Double(hl)).rounded(.up))                  // 336
        let pad = hl / 2 * 3                                                 // 1536
        let right = pad + le * hl - T
        var xp = reflectPad(x, left: pad, right: right)
        xp = reflectPad(xp, left: N / 2, right: N / 2)                       // center=True
        var re = [Float](repeating: 0, count: F * L), im = re
        var frame = [Float](repeating: 0, count: N)
        var fr = [Float](repeating: 0, count: N / 2 + 1), fi = fr
        let scale = 1 / Float(N).squareRoot()
        for f in 0..<L {
            let s0 = (f + 2) * hl                                            // Frames 2 ..< 2+le
            xp.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + s0, 1, window, 1, &frame, 1, vDSP_Length(N)) }
            fft.forward(frame, re: &fr, im: &fi)
            for k in 0..<F { re[k * L + f] = fr[k] * scale; im[k * L + f] = fi[k] * scale }
        }
        return (re, im)
    }

    private func ispec(re: [Float], im: [Float]) -> [Float] {
        let T = Self.segmentLength, hl = Self.hop, N = Self.nfft, F = Self.bins, L = Self.frames
        let pad = hl / 2 * 3
        let le = hl * Int((Double(T) / Double(hl)).rounded(.up)) + 2 * pad   // 347136
        let totalFrames = L + 4
        let outLen = (totalFrames - 1) * hl + N
        var acc = [Float](repeating: 0, count: outLen)
        var env = [Float](repeating: 0, count: outLen)
        var fr = [Float](repeating: 0, count: N / 2 + 1), fi = fr
        var out = [Float](repeating: 0, count: N)
        let scale = Float(N).squareRoot()
        for f in 0..<totalFrames {
            let src = f - 2
            if src >= 0 && src < L {
                for k in 0..<F { fr[k] = re[k * L + src] * scale; fi[k] = im[k * L + src] * scale }
                fr[F] = 0; fi[F] = 0
                fft.inverse(re: fr, im: fi, out: &out)
                for i in 0..<N { acc[f * hl + i] += out[i] * window[i] }
            }
            for i in 0..<N { env[f * hl + i] += window[i] * window[i] }
        }
        var res = [Float](repeating: 0, count: T)
        for i in 0..<T {
            let p = N / 2 + pad + i
            res[i] = p < min(outLen, N / 2 + le) ? acc[p] / max(env[p], 1e-11) : 0
        }
        return res
    }

    private func reflectPad(_ x: [Float], left: Int, right: Int) -> [Float] {
        var out = [Float](repeating: 0, count: x.count + left + right)
        for i in 0..<x.count { out[left + i] = x[i] }
        let n = x.count
        for i in 0..<left { out[left - 1 - i] = x[min(n - 1, i + 1)] }
        for i in 0..<right { out[left + n + i] = x[max(0, n - 2 - i)] }
        return out
    }
}

enum VoiceSeparation {
    /// Trennt Stimme und Hintergrund und mischt neu: Stimme + `backgroundLevel` × Rest (48-kHz-Ein/Ausgabe).
    static func apply(_ ch: [[Float]], sampleRate: Double, backgroundLevel: Double, progress: ((Double) -> Void)? = nil) -> [[Float]]? {
        guard let sep = DemucsSeparator.shared else { return nil }
        let mono = ch.count == 1
        let left = Resampler.resample(ch[0], from: sampleRate, to: DemucsSeparator.sampleRate)
        let right = mono ? left : Resampler.resample(ch[1], from: sampleRate, to: DemucsSeparator.sampleRate)
        guard let stems = try? sep.separate(stereo: [left, right], progress: progress) else { return nil }
        let bg = Float(backgroundLevel)
        var mixed: [[Float]] = []
        for c in 0..<(mono ? 1 : 2) {
            var m = [Float](repeating: 0, count: left.count)
            for i in 0..<m.count { m[i] = stems.vocals[c][i] + bg * stems.rest[c][i] }
            var up = Resampler.resample(m, from: DemucsSeparator.sampleRate, to: sampleRate)
            if up.count > ch[0].count { up.removeLast(up.count - ch[0].count) }
            while up.count < ch[0].count { up.append(0) }
            mixed.append(up)
        }
        return mixed
    }
}
