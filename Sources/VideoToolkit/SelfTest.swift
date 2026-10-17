import Foundation
import Accelerate

enum SelfTest {
    static func run() -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool, _ info: String = "") {
            print((cond ? "✓ " : "✗ ") + name + (info.isEmpty ? "" : "  (\(info))")); if !cond { ok = false }
        }
        // FFT-Rundlauf
        let fft = RealFFT(size: 1024)
        let x = (0..<1024).map { Float(sin(Double($0) * 0.05) + 0.5 * sin(Double($0) * 0.9)) }
        var re = [Float](repeating: 0, count: 513), im = re, y = [Float](repeating: 0, count: 1024)
        fft.forward(x, re: &re, im: &im); fft.inverse(re: re, im: im, out: &y)
        var err: Float = 0; for i in 0..<1024 { err = max(err, abs(x[i] - y[i])) }
        check("FFT Rundlauf", err < 1e-4, "max Fehler \(err)")

        // Synthetisches „Sprach“-Signal + Rauschen + Brummen
        let sr = 48000.0, n = Int(sr * 8)
        var rng = SystemRandomNumberGenerator()
        func noise() -> Float { Float.random(in: -1...1, using: &rng) }
        var clean = [Float](repeating: 0, count: n), noisy = clean
        for i in 0..<n {
            let t = Double(i) / sr
            let gate: Double = (Int(t * 2) % 2 == 0) ? 1 : 0     // 0,5-s-Wechsel Sprache/Pause
            let voice = gate * (0.25 * sin(2 * .pi * 220 * t) + 0.15 * sin(2 * .pi * 660 * t) + 0.08 * sin(2 * .pi * 1980 * t))
            clean[i] = Float(voice)
            noisy[i] = Float(voice) + 0.03 * noise() + 0.02 * Float(sin(2 * .pi * 50 * t)) + 0.01 * Float(sin(2 * .pi * 100 * t))
        }
        let pcm = PCMAudio(channels: [noisy], sampleRate: sr)
        let an = AudioAnalyzer.analyze(pcm)
        check("Brummen erkannt", an.humHz == 50, "hum \(an.humHz) Hz, \(an.humStrengthDB) dB")
        check("SNR plausibel", an.snrDB > 10 && an.snrDB < 60, "snr \(an.snrDB)")

        var s = AudioSettings(); s.noiseReduction = 0.8; s.humHz = 50
        let out = AudioProcessor.process(pcm, settings: s, noise: an.noiseProfile)
        // Pausen (t in [0.5,1.0)) sollen leiser werden, Sprache erhalten bleiben
        func rms(_ a: [Float], _ from: Double, _ to: Double) -> Float {
            var r: Float = 0; a.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress! + Int(from * sr), 1, &r, vDSP_Length((to - from) * sr)) }; return r
        }
        let pauseBefore = rms(noisy, 2.6, 2.9), pauseAfter = rms(out.channels[0], 2.6, 2.9)
        let voiceBefore = rms(noisy, 2.1, 2.4), voiceAfter = rms(out.channels[0], 2.1, 2.4)
        check("Rauschen in Pausen sinkt ≥ 15 dB", toDB(pauseBefore) - toDB(pauseAfter) > 15,
              String(format: "%.1f → %.1f dB", toDB(pauseBefore), toDB(pauseAfter)))
        check("Stimme bleibt erhalten (±2 dB)", abs(toDB(voiceBefore) - toDB(voiceAfter)) < 2,
              String(format: "%.1f → %.1f dB", toDB(voiceBefore), toDB(voiceAfter)))
        let an2 = AudioAnalyzer.analyze(out)
        check("Brummen entfernt", an2.humHz == 0, "hum \(an2.humHz)")

        // Lautheit + Limiter
        var l = AudioSettings(); l.normalize = true; l.targetLUFS = -16
        let loud = AudioProcessor.process(PCMAudio(channels: [clean], sampleRate: sr), settings: l, noise: nil)
        let lufs = integratedLoudness(loud.channels, sampleRate: sr)
        var peak: Float = 0; vDSP_maxmgv(loud.channels[0], 1, &peak, vDSP_Length(n))
        check("Lautheit ≈ −16 LUFS", abs(lufs + 16) < 1.5, String(format: "%.2f LUFS", lufs))
        check("Spitzen ≤ −1 dBFS", toDB(peak) <= -0.95, String(format: "%.2f dBFS", toDB(peak)))
        print(ok ? "Alle Tests bestanden." : "FEHLER.")
        return ok
    }
}
