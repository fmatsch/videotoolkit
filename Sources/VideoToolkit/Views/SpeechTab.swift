import SwiftUI
import UniformTypeIdentifiers

struct SpeechTab: View {
    @EnvironmentObject var project: Project
    @LocalState private var modelReady = Transcriber.isAvailable

    private let languages: [(String, String)] = [("auto", "Automatisch erkennen"), ("de", "Deutsch"), ("en", "Englisch"), ("fr", "Französisch"),
                                                  ("es", "Spanisch"), ("it", "Italienisch"), ("pt", "Portugiesisch"), ("nl", "Niederländisch"),
                                                  ("pl", "Polnisch"), ("tr", "Türkisch")]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !project.hasAudio {
                    Text("Diese Datei enthält keine Audiospur.").foregroundStyle(.secondary)
                } else {
                    transcription
                    if project.transcript != nil {
                        cutting
                        subtitles
                        transcriptList
                    }
                }
            }.padding(14)
        }
    }

    private var transcription: some View {
        SectionCard(title: "Sprache erkennen (Whisper)", icon: "text.bubble") {
            Text("Erkennt gesprochenen Text lokal mit Wort-Zeitstempeln – Grundlage für Untertitel und das automatische Kürzen von Pausen.")
                .font(.callout).foregroundStyle(.secondary)
            if !modelReady {
                Label("Whisper-Modell nicht gefunden", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                Text("Das Modell (ca. 630 MB) wird nicht mit der App ausgeliefert. Lade es einmalig mit „Scripts/fetch_models.sh whisper“ und baue die App neu, oder wähle den heruntergeladenen Ordner hier aus.")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                    p.message = "Ordner „whisper-large-v3-turbo“ wählen (enthält AudioEncoder.mlmodelc, tokenizer.json …)"
                    if p.runModal() == .OK, let u = p.url {
                        do { try ModelLocator.importModel(from: u, as: "Optional/whisper-large-v3-turbo"); modelReady = Transcriber.isAvailable }
                        catch { project.errorMessage = error.localizedDescription }
                    }
                } label: { Label("Modell importieren …", systemImage: "square.and.arrow.down") }
            } else {
                Picker("Sprache", selection: $project.speech.language) {
                    ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                HStack {
                    if let p = project.transcribing {
                        ProgressView(value: p.0).frame(maxWidth: 140)
                        Text(p.1).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Button("Abbrechen") { project.cancelTranscribe() }
                    } else {
                        Button { project.transcribe() } label: {
                            Label(project.transcript == nil ? "Transkribieren" : "Neu transkribieren", systemImage: "waveform.badge.mic")
                        }.buttonStyle(.borderedProminent)
                        if let t = project.transcript { Text("\(t.words.count) Wörter · \(t.language.uppercased())").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    private var cutting: some View {
        let s = $project.speech
        return SectionCard(title: "Pausen & Füllwörter kürzen", icon: "scissors") {
            Toggle("Lange Pausen kürzen", isOn: s.cutPauses)
            if project.speech.cutPauses {
                ParamSlider(title: "Pausen länger als (s)", value: s.pauseThreshold, range: 0.3...2.0, neutral: 0.7, format: "%.1f")
                ParamSlider(title: "Bleibt stehen vor/nach Wörtern (s)", value: s.padding, range: 0.05...0.4, neutral: 0.15, format: "%.2f")
            }
            Toggle("Füllwörter entfernen (äh, ähm, hm …)", isOn: s.removeFillers)
            if project.speech.cutPauses || project.speech.removeFillers {
                let total = max(project.duration, 0.1)
                Text(String(format: "%d Schnitte · %.1f s werden entfernt (%.0f %%). Das Video wird beim Export entsprechend kürzer; Schnittstellen liegen auf leisen Stellen.",
                            project.removedRanges.count, project.removedSeconds, project.removedSeconds / total * 100))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var subtitles: some View {
        let s = $project.speech
        return SectionCard(title: "Untertitel", icon: "captions.bubble") {
            Toggle("Untertitel ins Video einbrennen", isOn: s.burnSubtitles)
            if project.speech.burnSubtitles {
                ParamSlider(title: "Schriftgröße", value: s.subtitleScale, range: 0.6...1.8, neutral: 1, format: "%.2f×")
            }
            Button {
                guard let url = project.url else { return }
                let p = NSSavePanel(); p.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
                p.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".srt"
                if p.runModal() == .OK, let dest = p.url { project.exportSRT(to: dest) }
            } label: { Label("SRT-Datei speichern …", systemImage: "doc.text") }
            Text("\(project.cues.count) Untertitel. Die SRT berücksichtigt gekürzte Pausen.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var transcriptList: some View {
        SectionCard(title: "Transkript", icon: "list.bullet.rectangle") {
            ForEach(project.transcript?.segments ?? []) { seg in
                Button { project.seek(to: seg.start) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text(Project.format(seg.start)).monospacedDigit().font(.caption).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
                        Text(styled(seg)).font(.callout).multilineTextAlignment(.leading)
                    }
                }.buttonStyle(.plain)
                Divider()
            }
        }
    }

    /// Zeigt zu entfernende Wörter durchgestrichen und grau.
    private func styled(_ seg: SpeechSegment) -> AttributedString {
        var out = AttributedString()
        for w in seg.words.isEmpty ? [SpokenWord(text: seg.text, start: seg.start, end: seg.end)] : seg.words {
            var a = AttributedString(w.text + " ")
            let mid = (w.start + w.end) / 2
            if project.removedRanges.contains(where: { $0.start <= mid && $0.end >= mid }) {
                a.strikethroughStyle = .single; a.foregroundColor = .secondary
            }
            out += a
        }
        return out
    }
}
