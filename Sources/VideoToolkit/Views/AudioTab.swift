import SwiftUI

struct AudioTab: View {
    @EnvironmentObject var project: Project

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !project.hasAudio {
                    Text("Diese Datei enthält keine Audiospur.").foregroundStyle(.secondary)
                } else {
                    let a = $project.audio
                    preview
                    SectionCard(title: "Störgeräusche", icon: "waveform.badge.minus") {
                        if AIModels.deepFilterAvailable {
                            ParamSlider(title: "KI-Stimmenverbesserung (DeepFilterNet3)", value: a.aiDenoise, range: 0...1,
                                        help: "Neuronales Netz (Core ML, lokal) entfernt Rauschen und Nachhall aus Sprache. Nur im Export und Probehören wirksam.")
                        }
                        ParamSlider(title: "Rauschen reduzieren (klassisch)", value: a.noiseReduction, range: 0...1)
                        Picker("Netzbrummen", selection: a.humHz) {
                            Text("Aus").tag(0.0); Text("50 Hz").tag(50.0); Text("60 Hz").tag(60.0)
                        }.pickerStyle(.segmented)
                        ParamSlider(title: "Knackser und Klicks entfernen", value: a.declick, range: 0...1)
                        ParamSlider(title: "Raumhall verringern", value: a.dereverb, range: 0...1,
                                    help: "Unterdrückt späte Reflexionen – Sprache klingt trockener und näher.")
                        ParamSlider(title: "Tiefenfilter (Hz)", value: a.highPassHz, range: 0...200, format: "%.0f",
                                    help: "Entfernt Dröhnen, Wind und Trittschall. 0 = aus.")
                    }
                    SectionCard(title: "Stimme", icon: "person.wave.2") {
                        separation
                        ParamSlider(title: "Stimme klarer", value: a.clarity, range: 0...1,
                                    help: "Senkt Mulm bei ca. 300 Hz, hebt Präsenz und Luft an.")
                        ParamSlider(title: "Stimme in den Vordergrund", value: a.voiceFocus, range: 0...1,
                                    help: "Erkennt Sprache und dämpft Pausen und Umgebung.")
                        ParamSlider(title: "S-Laute entschärfen", value: a.deEss, range: 0...1)
                        ParamSlider(title: "Atemgeräusche absenken", value: a.breath, range: 0...1,
                                    help: "Erkennt Einatmen zwischen Sätzen (gleichmäßiges Rauschen ohne Stimmton) und senkt es ab.")
                    }
                    SectionCard(title: "Lautstärke", icon: "speaker.wave.3") {
                        ParamSlider(title: "Kompression", value: a.compression, range: 0...1,
                                    help: "Gleicht laute und leise Passagen an.")
                        Toggle("Auf Zielllautheit normalisieren", isOn: a.normalize)
                        if project.audio.normalize {
                            ParamSlider(title: "Ziel (LUFS)", value: a.targetLUFS, range: -30...(-8), neutral: -16, format: "%.0f")
                        }
                        Toggle("Spitzenbegrenzer (−1 dBFS)", isOn: a.limiter)
                    }
                    SectionCard(title: "Equalizer", icon: "slider.vertical.3") {
                        ParamSlider(title: "Bässe 100 Hz", value: a.eqLow, range: -12...12, format: "%+.1f dB")
                        ParamSlider(title: "Tiefmitten 300 Hz", value: a.eqLowMid, range: -12...12, format: "%+.1f dB")
                        ParamSlider(title: "Mitten 1 kHz", value: a.eqMid, range: -12...12, format: "%+.1f dB")
                        ParamSlider(title: "Präsenz 3,5 kHz", value: a.eqPresence, range: -12...12, format: "%+.1f dB")
                        ParamSlider(title: "Luft 10 kHz", value: a.eqAir, range: -12...12, format: "%+.1f dB")
                    }
                    Button("Alle Audioeinstellungen zurücksetzen") { project.resetAudio() }
                }
            }.padding(14)
        }
    }

    @ViewBuilder private var separation: some View {
        if DemucsSeparator.isAvailable {
            Toggle("Stimme vom Hintergrund trennen (Demucs)", isOn: $project.audio.aiSeparate)
            if project.audio.aiSeparate {
                ParamSlider(title: "Restpegel des Hintergrunds", value: $project.audio.backgroundLevel, range: 0...1, neutral: 0.15,
                            help: "0 = nur die Stimme, 1 = Original. Neuronales Netz (lokal); rechenintensiv, ca. 1× Echtzeit.")
            }
        } else {
            Text("Stimme vom Hintergrund trennen (Demucs): Modell nicht gefunden.").font(.callout)
            Text("Lade es einmalig mit „Scripts/fetch_models.sh demucs“ und baue die App neu, oder importiere den Ordner „htdemucs-ft-fused“.")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                p.message = "Ordner „htdemucs-ft-fused“ wählen (enthält htdemucs_ft_fused.mlpackage)"
                if p.runModal() == .OK, let u = p.url {
                    do { try ModelLocator.importModel(from: u, as: "Optional/htdemucs-ft-fused"); project.objectWillChange.send() }
                    catch { project.errorMessage = error.localizedDescription }
                }
            } label: { Label("Modell importieren …", systemImage: "square.and.arrow.down") }
        }
    }

    private var preview: some View {
        SectionCard(title: "Probehören", icon: "headphones") {
            HStack {
                Button { project.playAudioPreview(processed: false) } label: { Label("Original", systemImage: "play.fill") }
                Button { project.playAudioPreview(processed: true) } label: { Label("Bearbeitet", systemImage: "wand.and.stars") }
                    .buttonStyle(.borderedProminent)
                Button { project.stopAudio() } label: { Image(systemName: "stop.fill") }
            }
            Text(project.audioPreviewState ?? "Spielt 12 Sekunden ab der Vorschauposition. Änderungen wirken beim nächsten Abspielen.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
