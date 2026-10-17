import SwiftUI
import UniformTypeIdentifiers

struct ReferenceTab: View {
    @EnvironmentObject var project: Project
    @LocalState private var targeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionCard(title: "Referenzbild", icon: "photo") {
                    Text("Spiele ein Bild ein, dessen Look dein Video bekommen soll – etwa ein gut belichtetes Standbild aus einer anderen Aufnahme. Farben und Tonwerte werden daran ausgerichtet.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let ref = project.referenceImage {
                        Image(decorative: ref, scale: 1).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        HStack {
                            Text(project.referenceName ?? "").font(.caption).lineLimit(1)
                            Spacer()
                            if project.referenceBusy { ProgressView().controlSize(.small) }
                            Button("Entfernen") { project.clearReference() }
                        }
                        ParamSlider(title: "Stärke der Angleichung", value: $project.video.referenceStrength, range: 0...1, neutral: 0, format: "%.2f")
                    } else {
                        dropZone
                    }
                    Button { if let u = FilePanels.openImage() { project.loadReference(u) } } label: {
                        Label(project.referenceImage == nil ? "Bild wählen …" : "Anderes Bild wählen …", systemImage: "folder")
                    }
                }
                if project.referenceImage != nil {
                    Text("Die Angleichung orientiert sich an den bereits korrigierten Werten und aktualisiert sich automatisch, wenn du Belichtung oder Farbe änderst.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(14)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.and.arrow.down").font(.title)
            Text("Bild hierher ziehen")
        }
        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 26)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
            .foregroundStyle(targeted ? Color.accentColor : .secondary))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in project.loadReference(url) } }
            }
            return true
        }
    }
}
