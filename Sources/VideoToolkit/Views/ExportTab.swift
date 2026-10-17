import SwiftUI

struct ExportTab: View {
    @EnvironmentObject var project: Project

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionCard(title: "Export", icon: "square.and.arrow.up") {
                    if project.hasVideo {
                        Picker("Codec", selection: $project.exportOptions.codec) {
                            ForEach(ExportOptions.Codec.allCases) { Text($0.rawValue).tag($0) }
                        }
                        ParamSlider(title: "Qualität", value: $project.exportOptions.quality, range: 0.3...1, neutral: 0.7, format: "%.2f")
                        Toggle("Video-Korrekturen anwenden", isOn: $project.exportOptions.applyVideo)
                    }
                    if project.hasAudio {
                        Toggle("Audio-Korrekturen anwenden", isOn: $project.exportOptions.applyAudio)
                    }
                    summary
                    switch project.state {
                    case .exporting(let p, let text):
                        VStack(alignment: .leading) {
                            ProgressView(value: p) { Text(text).font(.caption) }
                            Button("Abbrechen") { project.cancelExport() }
                        }
                    default:
                        Button {
                            guard let url = project.url,
                                  let dest = FilePanels.saveVideo(suggested: url.deletingPathExtension().lastPathComponent + " – repariert.mp4") else { return }
                            project.export(to: dest)
                        } label: { Label("Reparierte Datei exportieren …", systemImage: "wand.and.stars").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                    if let out = project.lastExport {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Gespeichert: \(out.lastPathComponent)").font(.caption).lineLimit(1)
                            Spacer()
                            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                        }
                    }
                }
                Label("Verarbeitung findet ausschließlich lokal auf diesem Mac statt.", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(14)
        }
    }

    private var summary: some View {
        let v = project.video, a = project.audio
        var items: [String] = []
        if project.exportOptions.applyVideo && !v.isNeutral {
            if v.stabilize { items.append("Stabilisierung") }
            if v.deflicker { items.append("Flacker-Korrektur") }
            if v.denoiseSpatial > 0 || v.denoiseTemporal > 0 { items.append("Entrauschen") }
            if v.upscale > 1 { items.append("Hochskalierung \(v.upscale)×") }
            if v.referenceStrength > 0 && project.referenceImage != nil { items.append("Referenz-Look") }
            if v.exposure != 0 || v.shadows != 0 || v.highlights != 0 || v.contrast != 1 || v.temperature != 0 || v.saturation != 1 { items.append("Licht & Farbe") }
            if v.sharpen > 0 { items.append("Schärfen") }
        }
        if project.exportOptions.applyAudio && !a.isNeutral { items.append("Audio-Verbesserung") }
        return Text(items.isEmpty ? "Keine Korrekturen aktiv – die Datei wird neu kodiert." : "Aktiv: " + items.joined(separator: " · "))
            .font(.caption).foregroundStyle(.secondary)
    }
}
