import Foundation
import Accelerate
import CoreText
import CoreImage
import AppKit

struct TimeRange: Equatable { var start: Double; var end: Double; var length: Double { end - start } }

struct SpokenWord: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var start: Double
    var end: Double
}

struct SpeechSegment: Identifiable {
    let id: Int
    var start: Double
    var end: Double
    var text: String
    var words: [SpokenWord]
}

struct Transcript {
    var segments: [SpeechSegment]
    var language: String
    var words: [SpokenWord] { segments.flatMap(\.words) }
}

struct SpeechSettings: Equatable {
    var cutPauses = false
    var pauseThreshold = 0.7        // Pausen länger als … s werden gekürzt
    var padding = 0.15              // bleibt vor/nach den Wörtern stehen
    var removeFillers = false
    var burnSubtitles = false
    var subtitleScale = 1.0
    var language = "auto"
}

struct Cue: Equatable { var start: Double; var end: Double; var text: String }

enum SpeechEditor {
    static let fillers: Set<String> = ["äh", "ähm", "ahm", "öhm", "öh", "ehm", "eh", "uh", "uhm", "um", "hm", "hmm", "mhm", "erm"]

    static func normalized(_ w: String) -> String {
        w.lowercased().filter { $0.isLetter }
    }

    /// Bereiche, die entfernt werden (lange Pausen, Füllwörter). `energy` (10-ms-RMS) verfeinert die Schnittstellen auf leise Stellen.
    static func removedRanges(_ t: Transcript, settings s: SpeechSettings, duration: Double, mono: [Float]?, sampleRate: Double) -> [TimeRange] {
        guard s.cutPauses || s.removeFillers else { return [] }
        let words = t.words.filter { $0.end > $0.start }
        guard !words.isEmpty else { return [] }
        var removed: [TimeRange] = []

        if s.cutPauses {
            let pad = s.padding, thr = s.pauseThreshold
            func gap(_ a: Double, _ b: Double) {
                guard b - a > thr else { return }
                let r = TimeRange(start: a + pad, end: b - pad)
                if r.length >= 0.1 { removed.append(r) }
            }
            gap(0, words[0].start)
            for i in 1..<words.count { gap(words[i - 1].end, words[i].start) }
            gap(words.last!.end, duration)
        }
        if s.removeFillers {
            for w in words where fillers.contains(normalized(w.text)) {
                removed.append(TimeRange(start: max(0, w.start - 0.02), end: min(duration, w.end + 0.02)))
            }
        }
        removed = merge(removed)
        if let x = mono { removed = removed.map { refine($0, mono: x, sr: sampleRate) } }
        return merge(removed.filter { $0.length > 0.05 })
    }

    static func merge(_ r: [TimeRange]) -> [TimeRange] {
        var out: [TimeRange] = []
        for x in r.sorted(by: { $0.start < $1.start }) {
            if var last = out.last, x.start <= last.end + 0.001 { last.end = max(last.end, x.end); out[out.count - 1] = last } else { out.append(x) }
        }
        return out
    }

    /// Schnittgrenzen auf die leiseste 10-ms-Stelle in ±60 ms legen.
    private static func refine(_ r: TimeRange, mono x: [Float], sr: Double) -> TimeRange {
        func quietest(_ t: Double) -> Double {
            let blk = Int(sr * 0.01)
            var best = t, bestE = Float.greatestFiniteMagnitude
            var u = t - 0.06
            while u <= t + 0.06 {
                let i = Int(u * sr)
                if i >= 0, i + blk <= x.count {
                    var e: Float = 0
                    x.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + i, 1, &e, vDSP_Length(blk)) }
                    if e < bestE { bestE = e; best = u + 0.005 }
                }
                u += 0.01
            }
            return best
        }
        let s = r.start <= 0.001 ? r.start : quietest(r.start)
        return TimeRange(start: s, end: max(s, quietest(r.end)))
    }

    static func keepRanges(removed: [TimeRange], duration: Double) -> [TimeRange] {
        var keep: [TimeRange] = []
        var t = 0.0
        for r in removed {
            if r.start > t { keep.append(TimeRange(start: t, end: r.start)) }
            t = max(t, r.end)
        }
        if t < duration { keep.append(TimeRange(start: t, end: duration)) }
        return keep
    }

    /// Zeitpunkt der Originalaufnahme → Zeitpunkt nach dem Schnitt.
    static func mapTime(_ t: Double, removed: [TimeRange]) -> Double {
        var cut = 0.0
        for r in removed {
            if t >= r.end { cut += r.length } else if t > r.start { cut += t - r.start; break } else { break }
        }
        return t - cut
    }

    // MARK: Untertitel

    static func cues(from t: Transcript) -> [Cue] {
        var cues: [Cue] = []
        var cur: [SpokenWord] = []
        func text(_ w: [SpokenWord]) -> String { w.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") }
        func flush() {
            guard let f = cur.first, let l = cur.last else { return }
            cues.append(Cue(start: f.start, end: max(l.end, f.start + 0.4), text: wrap(text(cur))))
            cur = []
        }
        for w in t.words {
            if let last = cur.last, w.start - last.end > 0.8 { flush() }
            cur.append(w)
            let len = text(cur).count
            let dur = (cur.last!.end - cur.first!.start)
            let endsSentence = w.text.last.map { ".?!".contains($0) } ?? false
            if (endsSentence && len >= 18) || len >= 70 || dur > 5.5 { flush() }
        }
        flush()
        // Überlappungen vermeiden
        for i in 0..<max(0, cues.count - 1) where cues[i].end > cues[i + 1].start { cues[i].end = cues[i + 1].start }
        return cues
    }

    /// Bricht Text in höchstens zwei Zeilen à ~42 Zeichen.
    static func wrap(_ s: String) -> String {
        guard s.count > 42 else { return s }
        let words = s.split(separator: " ").map(String.init)
        var best = s, bestDiff = Int.max
        for i in 1..<max(1, words.count) {
            let a = words[..<i].joined(separator: " "), b = words[i...].joined(separator: " ")
            let diff = abs(a.count - b.count)
            if diff < bestDiff { bestDiff = diff; best = a + "\n" + b }
        }
        return best
    }

    static func srt(_ cues: [Cue], removed: [TimeRange] = []) -> String {
        func stamp(_ t: Double) -> String {
            let ms = Int((max(0, t) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        var out = "", n = 1
        for c in cues {
            // Cues, die komplett in entfernten Bereichen liegen, entfallen
            if removed.contains(where: { $0.start <= c.start && $0.end >= c.end }) { continue }
            let s = mapTime(c.start, removed: removed), e = mapTime(c.end, removed: removed)
            guard e - s > 0.05 else { continue }
            out += "\(n)\n\(stamp(s)) --> \(stamp(e))\n\(c.text)\n\n"; n += 1
        }
        return out
    }
}

/// Rendert Untertitel als Core-Image-Bild (weiße Schrift, halbtransparenter Kasten), zwischengespeichert pro Text.
final class SubtitleRenderer {
    private var cache: [String: CIImage] = [:]
    private let height: CGFloat, width: CGFloat, scale: Double

    init(displaySize: CGSize, scale: Double) { width = displaySize.width; height = displaySize.height; self.scale = scale }

    /// Bild im Anzeige-Koordinatensystem (y nach oben), Größe = Anzeigegröße.
    func overlay(for text: String) -> CIImage? {
        if let c = cache[text] { return c }
        let fontSize = max(14, height * 0.042 * scale)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: para]
        let maxW = width * 0.88
        let str = NSAttributedString(string: text, attributes: attrs)
        let bounds = str.boundingRect(with: CGSize(width: maxW, height: height), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let padX = fontSize * 0.5, padY = fontSize * 0.3
        let boxW = ceil(bounds.width) + 2 * padX, boxH = ceil(bounds.height) + 2 * padY
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let boxRect = CGRect(x: (width - boxW) / 2, y: height * 0.07, width: boxW, height: boxH)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.62))
        ctx.addPath(CGPath(roundedRect: boxRect, cornerWidth: fontSize * 0.3, cornerHeight: fontSize * 0.3, transform: nil)); ctx.fillPath()
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gc
        str.draw(with: CGRect(x: boxRect.minX + padX, y: boxRect.minY + padY, width: boxW - 2 * padX, height: ceil(bounds.height)),
                 options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return nil }
        let img = CIImage(cgImage: cg)
        cache[text] = img
        return img
    }
}

enum AudioCutter {
    /// Setzt die behaltenen Bereiche zusammen, mit 8-ms-Überblendung an jeder Schnittstelle (kein Knacksen).
    static func apply(_ pcm: PCMAudio, keep: [TimeRange]) -> PCMAudio {
        let sr = pcm.sampleRate
        let fade = max(8, Int(sr * 0.008))
        var out = [[Float]](repeating: [], count: pcm.channels.count)
        for (ri, r) in keep.enumerated() {
            let a = max(0, Int(r.start * sr)), b = min(pcm.frames, Int(r.end * sr))
            guard b > a else { continue }
            for c in 0..<pcm.channels.count {
                var seg = Array(pcm.channels[c][a..<b])
                let n = min(fade, seg.count / 2)
                if ri > 0 || a > 0 { for i in 0..<n { seg[i] *= Float(i) / Float(n) } }
                if ri < keep.count - 1 || b < pcm.frames { for i in 0..<n { seg[seg.count - 1 - i] *= Float(i) / Float(n) } }
                out[c].append(contentsOf: seg)
            }
        }
        return PCMAudio(channels: out, sampleRate: sr)
    }
}
