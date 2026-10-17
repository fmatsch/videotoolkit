import Foundation

/// Wendet alle empfohlenen Reparaturen an – gemeinsam genutzt von GUI und Kommandozeile.
enum AutoFix {
    static func defaultEnabled(video: [Issue], audio: [Issue]) -> Set<FixID> {
        Set((video + audio).filter { $0.severity > .info }.map(\.fix))
    }

    static func settings(video va: VideoAnalysis?, audio aa: AudioAnalysis?, enabled: Set<FixID>, intensity: Double,
                         base: (VideoSettings, AudioSettings) = (VideoSettings(), AudioSettings()))
        -> (VideoSettings, AudioSettings) {
        var v = base.0, a = base.1
        for fix in FixID.allCases {
            if fix.isAudio {
                if let aa { Diagnosis.apply(fix, enabled: enabled.contains(fix), to: &a, analysis: aa, intensity: intensity) }
            } else if let va {
                Diagnosis.apply(fix, enabled: enabled.contains(fix), to: &v, analysis: va, intensity: intensity)
            }
        }
        return (v, a)
    }
}
