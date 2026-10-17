import Foundation

/// Übersetzt Messwerte in verständliche Probleme und konkrete Korrekturwerte.
enum Diagnosis {

    // MARK: Video

    static func videoIssues(_ a: VideoAnalysis) -> [Issue] {
        var out: [Issue] = []
        func add(_ fix: FixID, _ title: String, _ detail: String, _ sev: Severity) {
            out.append(Issue(fix: fix, title: title, detail: detail, severity: sev))
        }
        let pct = { (v: Double) in String(format: "%.0f %%", v * 100) }

        if a.meanLuma < 0.30 {
            let sev: Severity = a.meanLuma < 0.15 ? .severe : a.meanLuma < 0.22 ? .moderate : .mild
            add(.exposure, "Zu dunkel", "Durchschnittliche Helligkeit \(pct(a.meanLuma)). Belichtung wird angehoben.", sev)
        } else if a.meanLuma > 0.68 {
            let sev: Severity = a.meanLuma > 0.8 ? .severe : a.meanLuma > 0.74 ? .moderate : .mild
            add(.exposure, "Überbelichtet", "Durchschnittliche Helligkeit \(pct(a.meanLuma)). Belichtung wird abgesenkt.", sev)
        }
        let backlit = a.faceLuma.map { $0 < 0.30 && a.meanLuma > $0 * 1.3 } ?? false
        if a.shadowClip > 0.2 || backlit {
            let detail = backlit ? "Gesichter sind deutlich dunkler als der Rest (Gegenlicht). Schatten werden aufgehellt."
                                 : "\(pct(a.shadowClip)) des Bildes sind abgesoffen. Schatten werden aufgehellt."
            add(.shadows, backlit ? "Gegenlicht / Gesicht zu dunkel" : "Abgesoffene Schatten", detail, a.shadowClip > 0.4 || backlit ? .moderate : .mild)
        }
        if a.highlightClip > 0.03 {
            add(.highlights, "Ausgebrannte Lichter", "\(pct(a.highlightClip)) des Bildes sind überstrahlt. Lichter werden zurückgeholt.",
                a.highlightClip > 0.12 ? .moderate : .mild)
        }
        let range = a.p99 - a.p1
        if range < 0.65 {
            add(.contrast, "Flaues Bild", String(format: "Tonwertumfang nur %.0f %% – Kontrast wird erhöht.", range * 100), range < 0.4 ? .moderate : .mild)
        }
        let wb = whiteBalanceGains(a)
        let cast = max(abs(wb.r - 1), abs(wb.b - 1), abs(wb.g - 1))
        if cast > 0.06 {
            let dir = wb.b > wb.r ? "Warmstich" : "Blaustich"
            let dir2 = wb.g > 1.06 ? " mit Magenta-Anteil" : wb.g < 0.94 ? " mit Grün-Anteil" : ""
            add(.whiteBalance, "Farbstich (\(dir)\(dir2))", "Neutrale Flächen sind nicht grau. Weißabgleich wird korrigiert.", cast > 0.2 ? .severe : cast > 0.12 ? .moderate : .mild)
        }
        if a.meanSaturation < 0.18 {
            add(.saturation, "Blasse Farben", "Mittlere Sättigung \(pct(a.meanSaturation)).", a.meanSaturation < 0.1 ? .moderate : .mild)
        } else if a.meanSaturation > 0.62 {
            add(.saturation, "Übersättigt", "Mittlere Sättigung \(pct(a.meanSaturation)).", .mild)
        }
        if a.noiseSigma > 0.010 {
            let sev: Severity = a.noiseSigma > 0.03 ? .severe : a.noiseSigma > 0.018 ? .moderate : .mild
            add(.denoise, "Bildrauschen", String(format: "Geschätztes Rauschen σ ≈ %.1f/255.", a.noiseSigma * 255), sev)
        }
        if a.sharpness < sharpnessThreshold {
            let sev: Severity = a.sharpness < sharpnessThreshold * 0.5 ? .moderate : .mild
            add(.sharpen, "Unscharf", "Feine Details fehlen. Schärfung wird hinzugefügt.", sev)
        }
        if a.shakePercent > 0.35 {
            let sev: Severity = a.shakePercent > 1.6 ? .severe : a.shakePercent > 0.8 ? .moderate : .mild
            add(.stabilize, "Verwackelt", String(format: "Kamerawackeln ≈ %.1f %% der Bildbreite.", a.shakePercent), sev)
        }
        if a.flickerPercent > 1.2 {
            add(.deflicker, "Helligkeitsflackern", String(format: "Frame-zu-Frame-Schwankung ≈ %.1f %%.", a.flickerPercent), a.flickerPercent > 3 ? .moderate : .mild)
        }
        if a.height < 720 {
            add(.upscale, "Niedrige Auflösung", "\(a.width)×\(a.height) – Hochskalierung auf 2×" + (AIModels.upscalerAvailable ? " mit KI (Real-ESRGAN, langsam)." : " mit Schärfung."), .info)
        }
        return out.sorted { $0.severity > $1.severity }
    }

    static let sharpnessThreshold = 0.20

    static func whiteBalanceGains(_ a: VideoAnalysis) -> (r: Double, g: Double, b: Double) {
        let n = a.neutralRGB
        let ref = max((n.x + n.y + n.z) / 3, 0.01)
        func c(_ v: Double) -> Double { min(1.3, max(0.77, ref / max(v, 0.01))) }
        return (c(n.x), c(n.y), c(n.z))
    }

    /// Setzt/entfernt die Felder einer Videokorrektur. `intensity` skaliert die Empfehlung (1 = empfohlen).
    static func apply(_ fix: FixID, enabled: Bool, to s: inout VideoSettings, analysis a: VideoAnalysis, intensity k: Double) {
        let neutral = VideoSettings()
        func mix(_ n: Double, _ rec: Double) -> Double { enabled ? n + (rec - n) * k : n }
        switch fix {
        case .exposure:
            let target = 0.42
            let ev = log2(target / max(a.meanLuma, 0.04))
            s.exposure = mix(neutral.exposure, max(-1.2, min(1.6, ev * 0.8)))
        case .shadows:
            s.shadows = mix(0, min(0.9, 0.35 + a.shadowClip))
        case .highlights:
            s.highlights = mix(0, min(0.9, 0.3 + a.highlightClip * 4))
        case .contrast:
            let range = a.p99 - a.p1
            s.contrast = mix(1, min(1.4, 1 + (0.8 - range) * 0.9))
        case .whiteBalance:
            let g = whiteBalanceGains(a)
            let temp = max(-1, min(1, (g.r - g.b) / 0.5))
            let tg = g.g / max(sqrt(g.r * g.b), 0.01)
            let tint = max(-1, min(1, (1 - tg) / 0.2))
            s.temperature = mix(0, temp)
            s.tint = mix(0, abs(tint) > 0.1 ? tint : 0)
        case .saturation:
            if a.meanSaturation > 0.62 { s.saturation = mix(1, 0.85); s.vibrance = mix(0, 0) }
            else { s.saturation = mix(1, min(1.5, 1 + (0.3 - a.meanSaturation) * 2.5)); s.vibrance = mix(0, 0.3) }
        case .denoise:
            s.denoiseSpatial = mix(0, min(1, max(0.2, a.noiseSigma / 0.04)))
            s.denoiseTemporal = mix(0, min(0.9, max(0.2, a.noiseSigma / 0.035)))
        case .sharpen:
            s.sharpen = mix(0, a.sharpness < sharpnessThreshold * 0.5 ? 1.1 : 0.6)
        case .stabilize:
            s.stabilize = enabled
            s.stabilizeStrength = 0.4 + 0.4 * min(1, a.shakePercent / 1.6)
        case .deflicker:
            s.deflicker = enabled
        case .upscale:
            s.upscale = enabled ? min(2, max(1.5, 1080.0 / Double(max(a.height, 1)))) : 1
            s.aiUpscale = enabled && AIModels.upscalerAvailable
            if enabled { s.sharpen = max(s.sharpen, 0.5) }
        default: break
        }
    }

    // MARK: Audio

    static func audioIssues(_ a: AudioAnalysis) -> [Issue] {
        var out: [Issue] = []
        func add(_ fix: FixID, _ title: String, _ detail: String, _ sev: Severity) {
            out.append(Issue(fix: fix, title: title, detail: detail, severity: sev))
        }
        if a.humHz > 0 {
            add(.audioHum, "Netzbrummen (\(Int(a.humHz)) Hz)", String(format: "Tonspitze %.0f dB über dem Umgebungsspektrum.", a.humStrengthDB),
                a.humStrengthDB > 28 ? .severe : a.humStrengthDB > 20 ? .moderate : .mild)
        }
        if a.rumbleDB > -12 {
            add(.audioRumble, "Tieffrequentes Dröhnen", "Viel Energie unter 80 Hz (Wind, Trittschall, Griffgeräusche).", a.rumbleDB > -4 ? .moderate : .mild)
        }
        if a.snrDB < 35 && a.noiseFloorDB > -62 {
            let sev: Severity = a.snrDB < 15 ? .severe : a.snrDB < 25 ? .moderate : .mild
            add(.audioNoise, "Hintergrundrauschen", String(format: "Abstand Nutzsignal zu Rauschen ≈ %.0f dB (Rauschteppich %.0f dBFS).", a.snrDB, a.noiseFloorDB), sev)
        }
        if a.mudDB > mudThreshold {
            add(.audioClarity, "Dumpfer, mulmiger Klang", String(format: "Überbetonte Tiefmitten (+%.0f dB gegenüber der Sprachpräsenz).", a.mudDB), a.mudDB > mudThreshold + 6 ? .moderate : .mild)
        } else if a.dullnessDB < dullThreshold {
            add(.audioClarity, "Fehlende Höhen / Sprache wenig präsent", String(format: "Höhenanteil %.0f dB unter dem Sprachbereich.", -a.dullnessDB), a.dullnessDB < dullThreshold - 8 ? .moderate : .mild)
        }
        if a.speechFraction > 0.15 && a.snrDB < 30 {
            add(.audioVoice, "Stimme geht im Umfeld unter", "Stimmen-Fokus hebt Sprache an und dämpft Pausen und Umgebung.", a.snrDB < 18 ? .moderate : .mild)
        }
        if a.sibilanceDB > sibilanceThreshold {
            add(.audioDeEss, "Scharfe S-Laute", "Zischlaute stechen hervor.", .mild)
        }
        if a.dynamicRangeDB > 32 {
            add(.audioDynamics, "Stark schwankende Lautstärke", String(format: "Pegelspanne ≈ %.0f dB – leise Passagen gehen unter.", a.dynamicRangeDB), a.dynamicRangeDB > 42 ? .moderate : .mild)
        }
        if a.clippedFraction > 0.0005 {
            add(.audioLoudness, "Übersteuerung", String(format: "%.2f %% der Samples sind am Anschlag. Pegel wird neu ausgesteuert und begrenzt.", a.clippedFraction * 100), a.clippedFraction > 0.005 ? .severe : .moderate)
        } else if a.loudnessLUFS < -23 {
            add(.audioLoudness, "Zu leise", String(format: "Lautheit %.0f LUFS – Ziel ist −16 LUFS.", a.loudnessLUFS), a.loudnessLUFS < -30 ? .moderate : .mild)
        } else if a.loudnessLUFS > -11 {
            add(.audioLoudness, "Zu laut", String(format: "Lautheit %.0f LUFS – Ziel ist −16 LUFS.", a.loudnessLUFS), .mild)
        }
        return out.sorted { $0.severity > $1.severity }
    }

    static let mudThreshold: Float = 12
    static let dullThreshold: Float = -16
    static let sibilanceThreshold: Float = -3

    static func apply(_ fix: FixID, enabled: Bool, to s: inout AudioSettings, analysis a: AudioAnalysis, intensity k: Double) {
        func mix(_ n: Double, _ rec: Double) -> Double { enabled ? n + (rec - n) * k : n }
        switch fix {
        case .audioHum: s.humHz = enabled ? a.humHz : 0
        case .audioRumble: s.highPassHz = mix(0, 90)
        case .audioNoise:
            let amount = min(1, max(0.3, Double(35 - a.snrDB) / 25))
            if AIModels.deepFilterAvailable {
                s.aiDenoise = mix(0, min(1, 0.6 + amount * 0.4))
                s.noiseReduction = mix(0, 0.2)
            } else {
                s.noiseReduction = mix(0, amount)
            }
        case .audioClarity: s.clarity = mix(0, 0.7)
        case .audioVoice: s.voiceFocus = mix(0, a.snrDB < 18 ? 0.7 : 0.45)
        case .audioDeEss: s.deEss = mix(0, 0.5)
        case .audioDynamics: s.compression = mix(0, 0.5)
        case .audioLoudness:
            s.normalize = enabled
            s.targetLUFS = -16
            s.limiter = true
        default: break
        }
    }
}
