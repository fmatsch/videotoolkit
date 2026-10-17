import Foundation
import Accelerate

struct AudioAnalysis {
    var duration: Double
    var peakDB: Float
    var clippedFraction: Double
    var loudnessLUFS: Double
    var noiseFloorDB: Float          // 10. Perzentil der Kurzzeit-Pegel
    var speechLevelDB: Float         // 90. Perzentil
    var snrDB: Float
    var humHz: Double                // 0 = keiner
    var humStrengthDB: Float
    var rumbleDB: Float              // Energie <80 Hz relativ zu 200–4000 Hz
    var mudDB: Float                 // 180–450 Hz relativ zu 1–3 kHz
    var dullnessDB: Float            // 4–8 kHz relativ zu 1–3 kHz
    var sibilanceDB: Float           // 5–9 kHz relativ zu 1–3 kHz
    var dynamicRangeDB: Float
    var speechFraction: Double
    var clicksPerMinute: Double
    var reverbRT60: Double?          // geschätzte Nachhallzeit (s) aus der Abklingsteilheit nach lauten Stellen
    var noiseProfile: NoiseProfile?
}

enum AudioAnalyzer {
    /// Schätzt die Nachhallzeit: Median der Abklingsteilheit (dB/s) an Pegelabfällen von ≥ 12 dB, als RT60 = 60 dB / Steilheit.
    static func decayRT60(_ L: [Float], floorDB: Float) -> Double? {
        var est: [Double] = []
        var i = 1
        while i < L.count - 1 {
            if L[i] > floorDB + 20 && L[i] >= L[i - 1] {
                var j = i
                while j + 1 < L.count && L[j + 1] <= L[j] + 1.0 && L[j + 1] > floorDB + 6 { j += 1 }
                let drop = Double(L[i] - L[j]), dur = Double(j - i) * 0.02
                if drop >= 12 && dur >= 0.04 { est.append(60 * dur / drop) }
                i = max(j, i + 1)
            } else { i += 1 }
        }
        guard est.count >= 4 else { return nil }
        return est.sorted()[est.count / 2]
    }

    static func analyze(_ pcm: PCMAudio) -> AudioAnalysis {
        let sr = pcm.sampleRate
        let mono = pcm.mono

        var peak: Float = 0
        var clipped = 0
        for ch in pcm.channels {
            var p: Float = 0
            vDSP_maxmgv(ch, 1, &p, vDSP_Length(ch.count))
            peak = max(peak, p)
            var run = 0
            for v in ch {
                if abs(v) >= 0.989 { run += 1 } else { if run >= 3 { clipped += run }; run = 0 }
            }
        }
        let clippedFraction = Double(clipped) / Double(max(1, pcm.frames * pcm.channels.count))

        // Kurzzeit-Pegel (50 ms)
        let blk = Int(sr * 0.05)
        var levels: [Float] = []
        var i = 0
        while i + blk <= mono.count {
            var r: Float = 0
            mono.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress! + i, 1, &r, vDSP_Length(blk)) }
            levels.append(toDB(r))
            i += blk
        }
        let nonSilent = levels.filter { $0 > -90 }
        let floorDB = percentile(nonSilent, 0.10)
        let speechDB = percentile(nonSilent, 0.90)
        let dyn = percentile(nonSilent, 0.95) - percentile(nonSilent, 0.10)
        let active = nonSilent.isEmpty ? 0 : Double(nonSilent.filter { $0 > floorDB + 10 }.count) / Double(nonSilent.count)

        // Spektrum
        let fftSize = 16384
        let spec = welchSpectrum(mono, fftSize: fftSize)
        func band(_ lo: Double, _ hi: Double) -> Float {
            max(bandPower(spec, fftSize: fftSize, sampleRate: sr, from: lo, to: hi), 1e-20)
        }
        let ref = band(1000, 3000)
        func rel(_ lo: Double, _ hi: Double) -> Float { 10 * log10(band(lo, hi) / ref) }

        // Brummen: Peak bei 50/60 Hz gegenüber Umgebung
        var humHz = 0.0
        var humDB: Float = 0
        let binHz = sr / Double(fftSize)
        for f in [50.0, 60.0] {
            let k = Int((f / binHz).rounded())
            guard k > 14, k + 30 < spec.count else { continue }
            let peakP = (k - 1...k + 1).map { spec[$0] }.max() ?? 0
            let neigh = (k - 12...k + 12).filter { abs($0 - k) > 3 }.map { spec[$0] }.sorted()
            let med = neigh[neigh.count / 2]
            let d = 10 * log10(max(peakP, 1e-20) / max(med, 1e-20))
            // Obertöne bestätigen
            let k2 = Int((2 * f / binHz).rounded())
            let peak2 = (k2 - 1...k2 + 1).map { spec[$0] }.max() ?? 0
            let neigh2 = (k2 - 12...k2 + 12).filter { abs($0 - k2) > 3 }.map { spec[$0] }.sorted()
            let d2 = 10 * log10(max(peak2, 1e-20) / max(neigh2[neigh2.count / 2], 1e-20))
            let narrow = 10 * log10(max(peakP, 1e-20) / max((spec[k - 4] + spec[k + 4]) / 2, 1e-20))
            if d > 10 && narrow > 6 && (d2 > 3 || d > 11) && d > humDB { humDB = Float(d); humHz = f }
        }

        let noise = AudioProcessor.estimateNoiseProfile(mono: mono, sampleRate: sr)

        // Knackser (Trockenlauf)
        var probe = Array(mono.prefix(Int(sr * 600)))
        let clicks = AudioProcessor.declick(&probe, amount: 0.5, dryRun: true)
        let clicksPerMin = Double(clicks) / max(Double(probe.count) / sr / 60, 0.05)

        // Nachhall: Abklingzeit nach Sprachenden (20-ms-Pegel)
        let blk20 = Int(sr * 0.02)
        var lv: [Float] = []
        var q = 0
        while q + blk20 <= mono.count && lv.count < 30_000 {
            var r: Float = 0
            mono.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress! + q, 1, &r, vDSP_Length(blk20)) }
            lv.append(toDB(r)); q += blk20
        }
        let t60 = decayRT60(lv, floorDB: floorDB)

        return AudioAnalysis(
            duration: pcm.duration, peakDB: toDB(peak), clippedFraction: clippedFraction,
            loudnessLUFS: integratedLoudness(pcm.channels, sampleRate: sr),
            noiseFloorDB: floorDB, speechLevelDB: speechDB, snrDB: speechDB - floorDB,
            humHz: humHz, humStrengthDB: humDB,
            rumbleDB: 10 * log10(band(20, 80) / band(200, 4000)),
            mudDB: rel(180, 450), dullnessDB: rel(4000, 8000), sibilanceDB: rel(5000, 9000),
            dynamicRangeDB: dyn, speechFraction: active, clicksPerMinute: clicksPerMin, reverbRT60: t60, noiseProfile: noise)
    }
}
