import Foundation

/// Alle Video-Korrekturen. Neutralwerte = keine Veränderung.
struct VideoSettings: Equatable {
    var exposure: Double = 0            // EV, -2 ... 2
    var shadows: Double = 0             // 0 ... 1  (Schatten aufhellen)
    var highlights: Double = 0          // 0 ... 1  (Lichter zurückholen)
    var contrast: Double = 1            // 0.6 ... 1.6
    var saturation: Double = 1          // 0 ... 2
    var vibrance: Double = 0            // -1 ... 1
    var temperature: Double = 0         // -1 (kühler) ... 1 (wärmer)
    var tint: Double = 0                // -1 (grün) ... 1 (magenta)
    var denoiseSpatial: Double = 0      // 0 ... 1
    var denoiseTemporal: Double = 0     // 0 ... 1
    var sharpen: Double = 0             // 0 ... 2
    var deflicker: Bool = false
    var stabilize: Bool = false
    var stabilizeStrength: Double = 0.6 // 0 ... 1 (Glättungsradius)
    var stabilizeRotation: Bool = true  // auch Kippen/Drehen ausgleichen
    var rollingShutter: Double = 0      // 0 ... 1 (Schräglage bei Schwenks)
    var lensCorrection: Double = 0      // -1 ... 1 (Tonnen-/Kissenverzeichnung)
    var vignetteFix: Double = 0         // 0 ... 1 (Randabdunklung aufhellen)
    var deband: Double = 0              // 0 ... 1 (Streifen in Verläufen verdecken)
    var deinterlace: Bool = false       // Kammartefakte entfernen
    var reframe: Reframe = .none        // Hochformat/Quadrat mit Personenverfolgung
    var upscale: Double = 1             // 1, 1.5, 2, 3
    var aiUpscale: Bool = false         // Real-ESRGAN statt Lanczos
    var referenceStrength: Double = 0   // 0 ... 1

    static let neutral = VideoSettings()
    var isNeutral: Bool { self == VideoSettings() }
    /// Nur Einstellungen, die das Referenz-LUT beeinflussen (alles vor dem Referenzschritt).
    var preReferenceKey: [Double] {
        [exposure, shadows, highlights, contrast, saturation, vibrance, temperature, tint]
    }
}

struct AudioSettings: Equatable {
    var aiDenoise: Double = 0           // 0 ... 1  (DeepFilterNet3, Core ML)
    var noiseReduction: Double = 0      // 0 ... 1
    var humHz: Double = 0               // 0 (aus), 50, 60
    var declick: Double = 0             // 0 ... 1 (Knackser/Klicks entfernen)
    var breath: Double = 0              // 0 ... 1 (Atemgeräusche absenken)
    var dereverb: Double = 0            // 0 ... 1 (Raumhall verringern)
    var aiSeparate: Bool = false        // Stimme vom Hintergrund trennen (Demucs)
    var backgroundLevel: Double = 0.15  // Restpegel des Hintergrunds, 0 = nur Stimme
    var highPassHz: Double = 0          // 0 (aus) ... 200
    var clarity: Double = 0             // 0 ... 1  (Stimme klarer: Mulm raus, Präsenz rein)
    var voiceFocus: Double = 0          // 0 ... 1  (Stimme in den Vordergrund)
    var deEss: Double = 0               // 0 ... 1
    var compression: Double = 0         // 0 ... 1
    var normalize: Bool = false
    var targetLUFS: Double = -16
    var limiter: Bool = true
    // Expert-EQ (dB)
    var eqLow: Double = 0               // Low-Shelf 100 Hz
    var eqLowMid: Double = 0            // 300 Hz
    var eqMid: Double = 0               // 1 kHz
    var eqPresence: Double = 0          // 3.5 kHz
    var eqAir: Double = 0               // High-Shelf 10 kHz

    var isNeutral: Bool {
        var s = self; s.limiter = true; s.targetLUFS = -16; s.backgroundLevel = 0.15
        return s == AudioSettings()
    }
}

/// Zielformat für den automatischen Bildausschnitt.
enum Reframe: String, CaseIterable, Identifiable {
    case none = "Original", vertical = "Hochformat 9:16", portrait = "Hochformat 4:5", square = "Quadrat 1:1"
    var id: String { rawValue }
    /// Breite / Höhe, nil = unverändert
    var aspect: Double? {
        switch self { case .none: nil; case .vertical: 9.0 / 16; case .portrait: 4.0 / 5; case .square: 1 }
    }
}

enum Severity: Int, Comparable {
    case ok = 0, info, mild, moderate, severe
    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    var label: String {
        switch self {
        case .ok: "In Ordnung"; case .info: "Hinweis"; case .mild: "Leicht"
        case .moderate: "Deutlich"; case .severe: "Stark"
        }
    }
}

/// Eine einzelne, einzeln zuschaltbare Reparatur.
enum FixID: String, CaseIterable, Identifiable {
    case exposure, shadows, highlights, contrast, whiteBalance, saturation
    case denoise, sharpen, stabilize, deflicker, upscale
    case audioHum, audioRumble, audioNoise, audioClarity, audioVoice, audioDynamics, audioLoudness, audioDeEss
    case rollingShutter, lens, vignette, deband, deinterlace
    case audioClicks, audioBreath, audioReverb, audioSeparate
    var id: String { rawValue }
    var isAudio: Bool { rawValue.hasPrefix("audio") }
}

struct Issue: Identifiable {
    let id = UUID()
    let fix: FixID
    let title: String
    let detail: String
    let severity: Severity
}
