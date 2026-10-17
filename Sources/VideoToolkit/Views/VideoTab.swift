import SwiftUI

struct VideoTab: View {
    @EnvironmentObject var project: Project

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !project.hasVideo {
                    Text("Diese Datei enthält kein Video.").foregroundStyle(.secondary)
                } else {
                    let v = $project.video
                    SectionCard(title: "Licht", icon: "sun.max") {
                        ParamSlider(title: "Belichtung (EV)", value: v.exposure, range: -2...2)
                        ParamSlider(title: "Schatten aufhellen", value: v.shadows, range: 0...1)
                        ParamSlider(title: "Lichter zurückholen", value: v.highlights, range: 0...1)
                        ParamSlider(title: "Kontrast", value: v.contrast, range: 0.6...1.6, neutral: 1)
                    }
                    SectionCard(title: "Farbe", icon: "paintpalette") {
                        ParamSlider(title: "Temperatur (kühl ↔ warm)", value: v.temperature, range: -1...1)
                        ParamSlider(title: "Tönung (grün ↔ magenta)", value: v.tint, range: -1...1)
                        ParamSlider(title: "Sättigung", value: v.saturation, range: 0...2, neutral: 1)
                        ParamSlider(title: "Dynamik (Vibrance)", value: v.vibrance, range: -1...1)
                    }
                    SectionCard(title: "Detail", icon: "sparkles") {
                        ParamSlider(title: "Entrauschen (räumlich)", value: v.denoiseSpatial, range: 0...1)
                        ParamSlider(title: "Entrauschen (zeitlich)", value: v.denoiseTemporal, range: 0...1,
                                    help: "Mittelt statische Bildbereiche über mehrere Frames. Nur im Export sichtbar.")
                        ParamSlider(title: "Schärfen", value: v.sharpen, range: 0...2)
                    }
                    SectionCard(title: "Bewegung & Flackern", icon: "gyroscope") {
                        Toggle("Stabilisieren", isOn: v.stabilize)
                        if project.video.stabilize {
                            ParamSlider(title: "Glättung", value: v.stabilizeStrength, range: 0...1, neutral: 0.6,
                                        help: "Stärker = ruhigere Kamera, aber mehr Bildausschnitt geht verloren.")
                            Toggle("Kippen und Drehen ausgleichen", isOn: v.stabilizeRotation)
                        }
                        ParamSlider(title: "Rolling Shutter (Schräglage bei Schwenks)", value: v.rollingShutter, range: 0...1,
                                    help: "Richtet senkrechte Linien auf, die bei schnellen Schwenks kippen. 1,0 entspricht einer Auslesezeit von einer ganzen Framedauer, bei Handys sind 0,4–0,8 typisch.")
                        Toggle("Helligkeitsflackern entfernen", isOn: v.deflicker)
                    }
                    SectionCard(title: "Objektiv & Bildfehler", icon: "camera.aperture") {
                        ParamSlider(title: "Verzeichnung (Weitwinkel)", value: v.lensCorrection, range: -1...1,
                                    help: "Positiv: Tonnenverzeichnung von Weitwinkel- und Actioncams entfernen, negativ: Kissenverzeichnung.")
                        ParamSlider(title: "Randabdunklung aufhellen", value: v.vignetteFix, range: 0...1)
                        ParamSlider(title: "Streifen in Verläufen verdecken", value: v.deband, range: 0...1,
                                    help: "Feines Rauschen gegen Banding. Nur im Export sichtbar.")
                        Toggle("Zeilensprung (Interlacing) entfernen", isOn: v.deinterlace)
                    }
                    SectionCard(title: "Auflösung", icon: "arrow.up.left.and.arrow.down.right") {
                        Picker("Hochskalieren", selection: v.upscale) {
                            Text("Original").tag(1.0); Text("1,5×").tag(1.5); Text("2×").tag(2.0); Text("3×").tag(3.0)
                        }.pickerStyle(.segmented)
                        if project.video.upscale > 1 && AIModels.upscalerAvailable {
                            Toggle("KI-Hochskalierung (Real-ESRGAN)", isOn: v.aiUpscale)
                            Text(project.video.aiUpscale ? "Rekonstruiert Details mit einem lokalen neuronalen Netz. Sehr langsam (bei 540p ca. 20 s Rechenzeit pro Videosekunde, bei 1080p noch mehr), nur im Export sichtbar."
                                                         : "Klassische Skalierung (schnell).").font(.caption).foregroundStyle(.secondary)
                        }
                        if let va = project.videoAnalysis, project.video.upscale > 1 {
                            Text("Ausgabe: \(Int(Double(va.width) * project.video.upscale))×\(Int(Double(va.height) * project.video.upscale))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Alle Videoeinstellungen zurücksetzen") { project.resetVideo() }
                }
            }.padding(14)
        }
    }
}
