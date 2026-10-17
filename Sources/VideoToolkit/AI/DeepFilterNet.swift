import Foundation
import CoreML
import Accelerate

/// Sprachverbesserung mit DeepFilterNet3 (Core ML, lokal). Das Netz liefert ERB-Maske und Deep-Filter-Koeffizienten;
/// STFT, Merkmalsberechnung, Normalisierung und Anwendung der Filter sind hier in Swift umgesetzt
/// (Ablauf nach Rikorose/DeepFilterNet und soniqo/speech-swift, jeweils Apache-2.0).
final class DeepFilterNet {
    struct Config {
        static let fft = 960, hop = 480, bins = 481, erb = 32, dfBins = 96, dfOrder = 5, dfLookahead = 2
        static let normAlpha: Float = 0.99
    }

    static let shared: DeepFilterNet? = try? DeepFilterNet()
    private let model: MLModel
    private let window: [Float], erbFb: [Float], erbInvFb: [Float]
    private let meanInit: [Float], unitInit: [Float]
    private let fwd: OpaquePointer, inv: OpaquePointer

    private static func floats(_ rel: String) throws -> [Float] {
        guard let u = ModelLocator.url(rel) else { throw CocoaError(.fileNoSuchFile) }
        let d = try Data(contentsOf: u)
        return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    init() throws {
        guard let m = ModelLocator.url("DeepFilterNet3/DeepFilterNet3.mlmodelc") else { throw CocoaError(.fileNoSuchFile) }
        let cfg = MLModelConfiguration(); cfg.computeUnits = .all
        model = try MLModel(contentsOf: m, configuration: cfg)
        window = try Self.floats("DeepFilterNet3/window.f32")
        erbFb = try Self.floats("DeepFilterNet3/erb_fb.f32")
        erbInvFb = try Self.floats("DeepFilterNet3/erb_inv_fb.f32")
        meanInit = try Self.floats("DeepFilterNet3/mean_norm_state.f32")
        unitInit = try Self.floats("DeepFilterNet3/unit_norm_state.f32")
        guard window.count == Config.fft, erbFb.count == Config.bins * Config.erb, erbInvFb.count == Config.bins * Config.erb,
              meanInit.count == Config.erb, unitInit.count == Config.dfBins,
              let f = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Config.fft), .FORWARD),
              let i = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Config.fft), .INVERSE) else { throw CocoaError(.fileReadCorruptFile) }
        fwd = f; inv = i
    }
    deinit { vDSP_DFT_DestroySetup(fwd); vDSP_DFT_DestroySetup(inv) }

    /// Verbessert Audio bei 48 kHz (mono). Lange Aufnahmen werden in überlappende Blöcke geteilt.
    func enhance(_ audio: [Float], progress: ((Double) -> Void)? = nil) throws -> [Float] {
        let chunk = 40 * 48_000, overlap = 48_000
        if audio.count <= chunk { return try core(audio) }
        var out = [Float](repeating: 0, count: audio.count)
        var start = 0
        while start < audio.count {
            let end = min(audio.count, start + chunk)
            let enh = try core(Array(audio[start..<end]))
            let first = start == 0, last = end == audio.count
            for i in 0..<enh.count {
                var w: Float = 1
                if !first && i < overlap { let s = sin(Float(i) / Float(overlap) * .pi / 2); w = s * s }
                if !last && i >= enh.count - overlap { let c = cos(Float(i - (enh.count - overlap)) / Float(overlap) * .pi / 2); w *= c * c }
                out[start + i] += enh[i] * w
            }
            progress?(Double(end) / Double(audio.count))
            if last { break }
            start += chunk - overlap
        }
        return out
    }

    private func stftForward(_ audio: [Float]) -> (re: [Float], im: [Float], frames: Int) {
        let N = Config.fft, H = Config.hop, B = Config.bins
        let buf = [Float](repeating: 0, count: N - H) + audio
        let frames = max(0, (buf.count - N) / H + 1)
        var re = [Float](repeating: 0, count: frames * B), im = re
        var win = [Float](repeating: 0, count: N), zero = win, oR = win, oI = win
        var scale = 1 / Float(N)
        for f in 0..<frames {
            buf.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + f * H, 1, window, 1, &win, 1, vDSP_Length(N)) }
            vDSP_DFT_Execute(fwd, win, zero, &oR, &oI)
            vDSP_vsmul(oR, 1, &scale, &oR, 1, vDSP_Length(B)); vDSP_vsmul(oI, 1, &scale, &oI, 1, vDSP_Length(B))
            for k in 0..<B { re[f * B + k] = oR[k]; im[f * B + k] = oI[k] }
        }
        return (re, im, frames)
    }

    private func stftInverse(re: [Float], im: [Float], frames: Int) -> [Float] {
        let N = Config.fft, H = Config.hop, B = Config.bins
        var out = [Float](repeating: 0, count: frames * H)
        var mem = [Float](repeating: 0, count: N - H)
        var fR = [Float](repeating: 0, count: N), fI = fR, oR = fR, oI = fR, w = fR
        for f in 0..<frames {
            for k in 0..<B { fR[k] = re[f * B + k]; fI[k] = im[f * B + k] }
            for k in 1..<(N / 2) { fR[N - k] = fR[k]; fI[N - k] = -fI[k] }
            vDSP_DFT_Execute(inv, fR, fI, &oR, &oI)
            vDSP_vmul(oR, 1, window, 1, &w, 1, vDSP_Length(N))
            for i in 0..<(N - H) { w[i] += mem[i] }
            for i in 0..<H { out[f * H + i] = w[i] }
            for i in 0..<(N - H) { mem[i] = w[H + i] }
        }
        return out
    }

    /// Ein Durchlauf mit frischem Zustand.
    private func core(_ samples: [Float]) throws -> [Float] {
        let N = Config.fft, H = Config.hop, B = Config.bins, E = Config.erb, D = Config.dfBins, O = Config.dfOrder
        guard !samples.isEmpty else { return [] }
        let padded = samples + [Float](repeating: 0, count: N)
        let (sRe, sIm, T) = stftForward(padded)
        guard T > 0 else { return [] }
        // ERB-Merkmale (dB), Mittelwert-Normalisierung
        var power = [Float](repeating: 0, count: T * B)
        for i in 0..<power.count { power[i] = sRe[i] * sRe[i] + sIm[i] * sIm[i] }
        var erb = [Float](repeating: 0, count: T * E)
        vDSP_mmul(power, 1, erbFb, 1, &erb, 1, vDSP_Length(T), vDSP_Length(E), vDSP_Length(B))
        var n32 = Int32(erb.count), eps: Float = 1e-10, ten: Float = 10
        vDSP_vsadd(erb, 1, &eps, &erb, 1, vDSP_Length(erb.count))
        vvlog10f(&erb, erb, &n32)
        vDSP_vsmul(erb, 1, &ten, &erb, 1, vDSP_Length(erb.count))
        var mean = meanInit
        let a = Config.normAlpha
        for t in 0..<T { for b in 0..<E {
            let x = erb[t * E + b]
            mean[b] = x * (1 - a) + mean[b] * a
            erb[t * E + b] = (x - mean[b]) / 40
        } }
        // Spektralmerkmale der untersten dfBins, Einheits-Normalisierung
        var fRe = [Float](repeating: 0, count: T * D), fIm = fRe
        var unit = unitInit
        for t in 0..<T { for f in 0..<D {
            let r = sRe[t * B + f], i = sIm[t * B + f]
            unit[f] = (r * r + i * i).squareRoot() * (1 - a) + unit[f] * a
            let nrm = max(unit[f], 1e-10).squareRoot()
            fRe[t * D + f] = r / nrm; fIm[t * D + f] = i / nrm
        } }
        // Core ML
        let erbIn = try MLMultiArray(shape: [1, 1, NSNumber(value: T), NSNumber(value: E)], dataType: .float32)
        erb.withUnsafeBufferPointer { erbIn.dataPointer.assumingMemoryBound(to: Float.self).update(from: $0.baseAddress!, count: T * E) }
        let specIn = try MLMultiArray(shape: [1, 2, NSNumber(value: T), NSNumber(value: D)], dataType: .float32)
        let sp = specIn.dataPointer.assumingMemoryBound(to: Float.self)
        fRe.withUnsafeBufferPointer { sp.update(from: $0.baseAddress!, count: T * D) }
        fIm.withUnsafeBufferPointer { (sp + T * D).update(from: $0.baseAddress!, count: T * D) }
        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "feat_erb": MLFeatureValue(multiArray: erbIn), "feat_spec": MLFeatureValue(multiArray: specIn),
        ]))
        guard let maskArr = result.featureValue(for: "erb_mask")?.multiArrayValue,
              let coefArr = result.featureValue(for: "df_coefs")?.multiArrayValue else { throw CocoaError(.coderValueNotFound) }
        let mask = Self.flatten(maskArr, count: T * E)        // [T, 32]
        let coefRaw = Self.flatten(coefArr, count: O * T * D * 2) // [O, T, D, 2]
        // ERB-Maske auf das volle Spektrum
        var full = [Float](repeating: 0, count: T * B)
        vDSP_mmul(mask, 1, erbInvFb, 1, &full, 1, vDSP_Length(T), vDSP_Length(B), vDSP_Length(E))
        var eRe = sRe, eIm = sIm
        vDSP_vmul(eRe, 1, full, 1, &eRe, 1, vDSP_Length(eRe.count))
        vDSP_vmul(eIm, 1, full, 1, &eIm, 1, vDSP_Length(eIm.count))
        // Deep Filtering auf den untersten Bins
        let padBefore = O - 1 - Config.dfLookahead
        for t in 0..<T { for f in 0..<D {
            var sr: Float = 0, si: Float = 0
            for n in 0..<O {
                let st = t + n - padBefore
                guard st >= 0, st < T else { continue }
                let ci = (((n * T + t) * D) + f) * 2
                let wr = coefRaw[ci], wi = coefRaw[ci + 1]
                let xr = sRe[st * B + f], xi = sIm[st * B + f]
                sr += xr * wr - xi * wi; si += xi * wr + xr * wi
            }
            eRe[t * B + f] = sr; eIm[t * B + f] = si
        } }
        let raw = stftInverse(re: eRe, im: eIm, frames: T)
        let trimStart = N - H
        let trimEnd = min(trimStart + samples.count, raw.count)
        guard trimEnd > trimStart else { return [] }
        var out = Array(raw[trimStart..<trimEnd])
        if out.count < samples.count { out += [Float](repeating: 0, count: samples.count - out.count) }
        return out
    }

    /// Liest ein MLMultiArray (float16/32, evtl. mit Zeilenabstand) in ein flaches C-geordnetes Array.
    static func flatten(_ a: MLMultiArray, count: Int) -> [Float] {
        let shape = a.shape.map(\.intValue), strides = a.strides.map(\.intValue)
        var out = [Float](repeating: 0, count: count)
        var contiguous = true
        var expected = 1
        for d in stride(from: shape.count - 1, through: 0, by: -1) { if strides[d] != expected && shape[d] > 1 { contiguous = false }; expected *= shape[d] }
        func read(_ idx: Int) -> Float {
            a.dataType == .float16 ? Float(a.dataPointer.assumingMemoryBound(to: Float16.self)[idx])
                                   : a.dataPointer.assumingMemoryBound(to: Float.self)[idx]
        }
        if contiguous {
            if a.dataType == .float32 {
                out.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: a.dataPointer.assumingMemoryBound(to: Float.self), count: count) }
            } else { for i in 0..<count { out[i] = read(i) } }
        } else {
            var idx = [Int](repeating: 0, count: shape.count)
            for i in 0..<count {
                var off = 0
                for d in 0..<shape.count { off += idx[d] * strides[d] }
                out[i] = read(off)
                var d = shape.count - 1
                while d >= 0 { idx[d] += 1; if idx[d] < shape[d] { break }; idx[d] = 0; d -= 1 }
            }
        }
        return out
    }
}
