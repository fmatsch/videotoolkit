import Foundation
import Accelerate

/// Stationäres Rauschprofil (Leistung pro FFT-Bin, 1024er-STFT).
struct NoiseProfile {
    var psd: [Float]
}

/// Lokale Audioverarbeitung (kein Netzwerk, keine Cloud): Brummfilter, spektrale Rauschminderung,
/// Stimmen-Fokus, EQ, De-Esser, Kompressor, Lautheitsnormalisierung, Limiter.
enum AudioProcessor {
    static let N = 1024
    static let H = 256

    private static let window: [Float] = (0..<N).map {
        Float(sqrt(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(N))))
    }

    // MARK: Rauschprofil

    /// Mittelt die leisesten ~10 % der Frames als Rauschmodell.
    static func estimateNoiseProfile(mono: [Float], sampleRate: Double) -> NoiseProfile? {
        let hop = N / 2
        guard mono.count > N * 8 else { return nil }
        let fft = RealFFT(size: N)
        var frames: [(energy: Float, start: Int)] = []
        var start = 0
        while start + N <= mono.count {
            var ms: Float = 0
            mono.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + start, 1, &ms, vDSP_Length(N)) }
            frames.append((ms, start))
            start += hop
        }
        let valid = frames.filter { $0.energy > 1e-11 }
        guard valid.count > 20 else { return nil }
        let quiet = valid.sorted { $0.energy < $1.energy }.prefix(max(10, valid.count / 10))
        var psd = [Float](repeating: 0, count: N / 2 + 1)
        var re = psd, im = psd, seg = [Float](repeating: 0, count: N)
        for f in quiet {
            mono.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + f.start, 1, window, 1, &seg, 1, vDSP_Length(N)) }
            fft.forward(seg, re: &re, im: &im)
            for k in 0..<psd.count { psd[k] += re[k] * re[k] + im[k] * im[k] }
        }
        let inv = 1 / Float(quiet.count)
        for k in 0..<psd.count { psd[k] = max(psd[k] * inv, 1e-14) }
        return NoiseProfile(psd: psd)
    }

    // MARK: Hauptpipeline

    static func process(_ input: PCMAudio, settings s: AudioSettings, noise: NoiseProfile?,
                        progress: ((Double) -> Void)? = nil) -> PCMAudio {
        var ch = input.channels
        let sr = input.sampleRate
        guard !s.isNeutral, input.frames > 0 else { return input }

        // 1. Netzbrummen: Kerbfilter auf Grundton + Obertönen
        if s.humHz > 0 {
            for c in 0..<ch.count {
                for h in 1...4 where s.humHz * Double(h) < sr * 0.45 {
                    var f = Biquad(.notch, freq: s.humHz * Double(h), sampleRate: sr, q: 25)
                    f.process(&ch[c])
                }
            }
        }
        // 2. Hochpass
        var hpFreq = s.highPassHz
        if s.clarity > 0.3 { hpFreq = max(hpFreq, 70) }
        if hpFreq > 0 {
            for c in 0..<ch.count {
                var f = Biquad(.highPass, freq: hpFreq, sampleRate: sr, q: 0.7071); f.process(&ch[c])
                var f2 = Biquad(.highPass, freq: hpFreq, sampleRate: sr, q: 0.7071); f2.process(&ch[c])
            }
        }
        progress?(0.1)
        // 2b. KI-Stimmenverbesserung (DeepFilterNet3)
        var aiApplied = false
        if s.aiDenoise > 0, let dfn = DeepFilterNet.shared {
            let mix = Float(s.aiDenoise)
            for c in 0..<ch.count {
                if let enh = try? dfn.enhance(ch[c]) {
                    for i in 0..<ch[c].count { ch[c][i] = ch[c][i] * (1 - mix) + enh[i] * mix }
                    aiApplied = true
                }
            }
        }
        // 3. Spektrale Rauschminderung + Stimmen-Fokus
        if s.noiseReduction > 0 || s.voiceFocus > 0 {
            let profile = (aiApplied ? nil : noise) ?? estimateNoiseProfile(mono: PCMAudio(channels: ch, sampleRate: sr).mono, sampleRate: sr)
            ch = spectralStage(ch, sampleRate: sr, amount: s.noiseReduction, focus: s.voiceFocus,
                               noise: profile) { progress?(0.1 + 0.6 * $0) }
        }
        progress?(0.7)
        // 4. EQ
        let bands: [(Biquad.Kind, Double, Double, Double)] = [
            (.lowShelf, 100, 0.7, s.eqLow),
            (.peaking, 300, 1.0, s.eqLowMid - 4.5 * s.clarity),
            (.peaking, 1000, 0.8, s.eqMid),
            (.peaking, 3300, 0.9, s.eqPresence + 3.5 * s.clarity),
            (.highShelf, 9000, 0.7, s.eqAir + 2.0 * s.clarity),
        ]
        for (kind, f, q, g) in bands where abs(g) > 0.05 {
            for c in 0..<ch.count {
                var bq = Biquad(kind, freq: f, sampleRate: sr, q: q, gainDB: g)
                bq.process(&ch[c])
            }
        }
        // 5. De-Esser
        if s.deEss > 0 { for c in 0..<ch.count { deEss(&ch[c], sampleRate: sr, amount: s.deEss) } }
        // 6. Kompressor
        if s.compression > 0 { compress(&ch, sampleRate: sr, amount: s.compression) }
        progress?(0.85)
        // 7. Lautheit
        if s.normalize {
            let l = integratedLoudness(ch, sampleRate: sr)
            if l > -60 {
                let g = Float(min(30, max(-24, s.targetLUFS - l)))
                let lin = fromDB(g)
                for c in 0..<ch.count { vDSP_vsmul(ch[c], 1, [lin], &ch[c], 1, vDSP_Length(ch[c].count)) }
            }
        }
        // 8. Limiter (immer als Sicherheit, wenn aktiviert)
        if s.limiter { limit(&ch, sampleRate: sr, ceilingDB: -1.0) }
        progress?(1)
        return PCMAudio(channels: ch, sampleRate: sr)
    }

    // MARK: Spektralstufe

    private static func spectralStage(_ channels: [[Float]], sampleRate sr: Double, amount: Double, focus: Double,
                                      noise: NoiseProfile?, progress: (Double) -> Void) -> [[Float]] {
        let nCh = channels.count
        let n = channels[0].count
        let bins = N / 2 + 1
        let fft = RealFFT(size: N)
        let pad = N - H
        let totalFrames = (n + pad - 1) / H + 1
        let outLen = (totalFrames - 1) * H + N

        var padded = [[Float]](repeating: [Float](repeating: 0, count: outLen), count: nCh)
        for c in 0..<nCh { padded[c].replaceSubrange(pad..<(pad + n), with: channels[c]) }
        var out = [[Float]](repeating: [Float](repeating: 0, count: outLen), count: nCh)

        let noisePSD = noise?.psd ?? [Float](repeating: 1e-12, count: bins)
        let binHz = Float(sr) / Float(N)
        let sLo = max(1, Int(300 / binHz)), sHi = min(bins - 1, Int(3400 / binHz))
        let focusLo = Int(100 / binHz), focusHi = min(bins - 1, Int(7500 / binHz))

        let amt = Float(amount)
        let floorGain = amount > 0 ? fromDB(-(6 + 24 * amt)) : 1
        let mu: Float = 1 + 2 * amt
        let f = Float(focus)

        var gains = [Float](repeating: 1, count: bins)
        var prevG = [Float](repeating: 1, count: bins)
        var prevClean = [Float](repeating: 0, count: bins)
        var p = [Float](repeating: 0, count: bins)
        var re = [[Float]](repeating: [Float](repeating: 0, count: bins), count: nCh)
        var im = re
        var seg = [Float](repeating: 0, count: N)
        var vad: Float = 0

        for t in 0..<totalFrames {
            let s0 = t * H
            for c in 0..<nCh {
                padded[c].withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + s0, 1, window, 1, &seg, 1, vDSP_Length(N)) }
                fft.forward(seg, re: &re[c], im: &im[c])
            }
            for k in 0..<bins {
                var e: Float = 0
                for c in 0..<nCh { e += re[c][k] * re[c][k] + im[c][k] * im[c][k] }
                p[k] = e / Float(nCh)
            }
            // Sprachwahrscheinlichkeit aus dem SNR im Sprachband
            var ps: Float = 0, ns: Float = 0
            for k in sLo...sHi { ps += p[k]; ns += noisePSD[k] }
            let snrDB = 10 * log10(max(ps, 1e-14) / max(ns, 1e-14))
            let target = min(1, max(0, (snrDB - 4) / 10))
            vad = target > vad ? vad + 0.7 * (target - vad) : vad * 0.985 + target * 0.015

            // Wiener-Gewinn mit Decision-Directed-Schätzung
            for k in 0..<bins {
                let nk = noisePSD[k]
                let post = p[k] / nk
                let xi = 0.96 * prevClean[k] / nk + 0.04 * max(post - 1, 0)
                var g = amount > 0 ? max(floorGain, xi / (xi + mu)) : 1
                // Zeitglättung: schnell auf, langsam zu
                g = g > prevG[k] ? prevG[k] + 0.7 * (g - prevG[k]) : prevG[k] + 0.35 * (g - prevG[k])
                gains[k] = g
            }
            // Frequenzglättung
            var sm = gains
            for k in 1..<(bins - 1) { sm[k] = 0.25 * gains[k - 1] + 0.5 * gains[k] + 0.25 * gains[k + 1] }
            for k in 0..<bins {
                prevG[k] = sm[k]
                prevClean[k] = sm[k] * sm[k] * p[k]
            }
            // Stimmen-Fokus
            if f > 0 {
                let nonSpeech = fromDB(-18 * f * (1 - vad))
                let outBand = fromDB(-9 * f * vad)
                for k in 0..<bins {
                    var g = nonSpeech
                    if k < focusLo || k > focusHi { g *= outBand }
                    sm[k] *= g
                }
            }
            for c in 0..<nCh {
                for k in 0..<bins { re[c][k] *= sm[k]; im[c][k] *= sm[k] }
                fft.inverse(re: re[c], im: im[c], out: &seg)
                out[c].withUnsafeMutableBufferPointer { op in
                    for i in 0..<N { op[s0 + i] += seg[i] * window[i] * 0.5 }
                }
            }
            if t % 2000 == 0 { progress(Double(t) / Double(totalFrames)) }
        }
        return out.map { Array($0[pad..<(pad + n)]) }
    }

    // MARK: De-Esser, Kompressor, Limiter

    private static func deEss(_ x: inout [Float], sampleRate sr: Double, amount: Double) {
        var band = x
        var bp = Biquad(.bandPass, freq: 7000, sampleRate: sr, q: 0.9)
        bp.process(&band)
        // Hüllkurve
        let att = Float(1 - exp(-1 / (0.001 * sr))), rel = Float(1 - exp(-1 / (0.03 * sr)))
        var env = [Float](repeating: 0, count: x.count)
        var e: Float = 0
        for i in 0..<x.count {
            let a = abs(band[i])
            e += (a > e ? att : rel) * (a - e)
            env[i] = e
        }
        let thr = max(percentile(stride(from: 0, to: env.count, by: 16).map { env[$0] }, 0.85), 1e-5)
        let ratio = Float(1 + 3 * amount)
        let expo = 1 - 1 / ratio
        for i in 0..<x.count where env[i] > thr {
            let g = pow(thr / env[i], expo)
            x[i] -= band[i] * (1 - g)
        }
    }

    private static func compress(_ ch: inout [[Float]], sampleRate sr: Double, amount: Double) {
        let n = ch[0].count
        let ratio = Float(1 + 3.5 * amount)
        let thrDB: Float = -28 + Float(6 * (1 - amount))
        let att = Float(1 - exp(-1 / (0.008 * sr))), rel = Float(1 - exp(-1 / (0.18 * sr)))
        var env: Float = 0
        let makeup = fromDB(-thrDB * (1 - 1 / ratio) * 0.45)
        for i in 0..<n {
            var peak: Float = 0
            for c in 0..<ch.count { peak = max(peak, abs(ch[c][i])) }
            env += (peak > env ? att : rel) * (peak - env)
            let lvl = toDB(env)
            var gDB: Float = 0
            if lvl > thrDB { gDB = -(lvl - thrDB) * (1 - 1 / ratio) }
            let g = fromDB(gDB) * makeup
            for c in 0..<ch.count { ch[c][i] *= g }
        }
    }

    static func limit(_ ch: inout [[Float]], sampleRate sr: Double, ceilingDB: Float) {
        let n = ch[0].count
        guard n > 0 else { return }
        let ceil = fromDB(ceilingDB)
        let L = max(8, Int(0.003 * sr))
        var g = [Float](repeating: 1, count: n)
        var any = false
        for i in 0..<n {
            var pk: Float = 0
            for c in 0..<ch.count { pk = max(pk, abs(ch[c][i])) }
            if pk > ceil { g[i] = ceil / pk; any = true }
        }
        guard any else { return }
        // gleitendes Minimum über [i, i+L)
        var m = [Float](repeating: 1, count: n)
        var dq = [Int](repeating: 0, count: n + 1)
        var head = 0, tail = 0
        for i in stride(from: n - 1, through: 0, by: -1) {
            while tail > head, g[dq[tail - 1]] >= g[i] { tail -= 1 }
            dq[tail] = i; tail += 1
            while dq[head] >= i + L { head += 1 }
            m[i] = g[dq[head]]
        }
        // Box-Mittel über [i-L+1, i]
        var sm = [Float](repeating: 1, count: n)
        var run: Float = 0
        for i in 0..<n {
            run += m[i]
            if i >= L { run -= m[i - L] }
            let cnt = min(i + 1, L)
            // fehlende Werte vor Beginn zählen als 1
            sm[i] = (run + Float(L - cnt)) / Float(L)
        }
        // Freigabe glätten, ohne die Obergrenze zu verletzen
        let relC = Float(1 - exp(-1 / (0.08 * sr)))
        var prev: Float = 1
        for i in 0..<n {
            let target = sm[i]
            prev = target < prev ? target : prev + relC * (target - prev)
            let gg = min(prev, target)
            for c in 0..<ch.count { ch[c][i] = max(-ceil, min(ceil, ch[c][i] * gg)) }
        }
    }
}
