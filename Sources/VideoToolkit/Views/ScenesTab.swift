import SwiftUI

struct ScenesTab: View {
    @EnvironmentObject var project: Project

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !project.hasVideo {
                    Text("Dieser Modus benötigt ein Video.").foregroundStyle(.secondary)
                } else {
                    intro
                    if project.sceneMode {
                        detection
                        reference
                        matching
                        sceneList
                    }
                }
            }.padding(14)
        }
    }

    private var intro: some View {
        SectionCard(title: "Szenen-Angleich", icon: "rectangle.split.3x1") {
            Text("Für Videos aus mehreren Einstellungen: Das Video wird an den Schnitten getrennt, jede Szene wird an ein Referenzbild aus dem Video angeglichen und anschließend wieder zusammengesetzt. So sehen alle Szenen gleich aus.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Szenen-Modus aktivieren", isOn: $project.sceneMode).toggleStyle(.switch)
            if project.sceneMode {
                Text("Im Szenen-Modus ersetzt der Angleich die globalen Licht- und Farbregler. Entrauschen, Schärfen, Stabilisieren und Flackern bleiben aktiv – und arbeiten szenenweise.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var detection: some View {
        SectionCard(title: "1 · Schnitte erkennen", icon: "scissors") {
            ParamSlider(title: "Empfindlichkeit", value: $project.sceneSensitivity, range: 0...1, neutral: 0.5, format: "%.2f",
                        help: "Höher = mehr Schnitte (auch sanfte Übergänge), niedriger = nur harte Schnitte.")
            HStack {
                Button { project.detectScenes() } label: { Label("Neu erkennen", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(project.sceneProgress != nil)
                if let p = project.sceneProgress {
                    ProgressView(value: p.0).frame(maxWidth: 120)
                    Text(p.1).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(project.scenes.count) Szenen").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var reference: some View {
        SectionCard(title: "2 · Referenz wählen", icon: "scope") {
            Text("Spiele im Video an eine Stelle, deren Look für alle gelten soll, und übernimm das Bild.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 10) {
                if let ref = project.sceneReference {
                    Image(decorative: ref, scale: 1).resizable().scaledToFit().frame(width: 130)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Referenz").font(.caption.bold())
                        Text(project.sceneReferenceLabel ?? "").font(.caption).foregroundStyle(.secondary)
                        if let id = project.sceneReferenceSceneID { Text("Szene \(id + 1)").font(.caption).foregroundStyle(.secondary) }
                    }
                } else {
                    Text("Noch keine Referenz gewählt.").font(.callout).foregroundStyle(.orange)
                }
            }
            HStack {
                Button { project.useCurrentFrameAsSceneReference() } label: {
                    Label("Aktuelles Bild (\(Project.format(project.previewTime)))", systemImage: "camera.viewfinder")
                }.buttonStyle(.borderedProminent)
                Button { if let u = FilePanels.openImage() { project.useImageFileAsSceneReference(u) } } label: {
                    Label("Bild aus Datei …", systemImage: "photo")
                }
            }
        }
    }

    private var matching: some View {
        SectionCard(title: "3 · Angleichung", icon: "slider.horizontal.3") {
            Picker("Modus", selection: $project.sceneMatchMode) {
                ForEach(MatchMode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            Text(project.sceneMatchMode == .soft
                 ? "Gleicht Farbstich, Helligkeit und Kontrast an – schonend, ändert die Bildwirkung kaum."
                 : "Gleicht die komplette Tonwertverteilung an – kräftiger, kann bei sehr unterschiedlichen Motiven zu stark wirken.")
                .font(.caption).foregroundStyle(.secondary)
            ParamSlider(title: "Stärke", value: $project.sceneMatchStrength, range: 0...1, neutral: 0.85, format: "%.2f")
        }
    }

    private var sceneList: some View {
        SectionCard(title: "Szenen", icon: "film.stack") {
            if project.scenes.isEmpty {
                Text(project.sceneProgress == nil ? "Keine Szenen erkannt." : "Wird erkannt …").font(.callout).foregroundStyle(.secondary)
            }
            ForEach($project.scenes) { $scene in
                let idx = scene.id
                let active = project.sceneIndex(at: project.previewTime) == idx
                HStack(spacing: 10) {
                    Toggle("", isOn: $scene.enabled).labelsHidden().toggleStyle(.checkbox)
                        .help("Aus = Szene bleibt unverändert")
                    Group {
                        if let t = scene.thumbnail {
                            Image(decorative: t, scale: 1).resizable().scaledToFill()
                        } else { Color.gray.opacity(0.3) }
                    }
                    .frame(width: 80, height: 45).clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(active ? Color.accentColor : .clear, lineWidth: 2))
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text("Szene \(idx + 1)").font(.callout.weight(.semibold))
                            if project.sceneReferenceSceneID == idx { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
                        }
                        Text("\(Project.format(scene.start)) – \(Project.format(scene.end)) · \(String(format: "%.1f", scene.duration)) s")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { project.previewTime = min(scene.start + 0.2, max(0, project.duration - 0.1)) } label: { Image(systemName: "eye") }
                        .buttonStyle(.borderless).help("In der Vorschau zeigen")
                }
                if idx != project.scenes.last?.id { Divider() }
            }
        }
    }
}
