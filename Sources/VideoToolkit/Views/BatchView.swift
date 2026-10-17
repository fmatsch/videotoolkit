import SwiftUI
import UniformTypeIdentifiers

struct BatchView: View {
    @EnvironmentObject var project: Project
    @ObservedObject var queue: BatchQueue
    @Environment(\.dismiss) private var dismiss
    @LocalState private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Stapelverarbeitung").font(.title2.bold())
                Spacer()
                Button("Schließen") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("Modus", selection: $queue.mode) { ForEach(BatchQueue.Mode.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.radioGroup).disabled(queue.running)
            if queue.mode == .same {
                Text(project.url == nil ? "Öffne zuerst ein Video und stelle dessen Korrekturen ein – sie werden dann für alle Dateien verwendet." :
                     "Verwendet die aktuellen Video- und Audio-Einstellungen von „\(project.url!.lastPathComponent)“.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if project.referenceImage != nil {
                Toggle("Referenzbild „\(project.referenceName ?? "")“ auf jede Datei anwenden", isOn: $queue.applyReference).disabled(queue.running)
            }
            HStack {
                Picker("Codec", selection: $queue.options.codec) { ForEach(ExportOptions.Codec.allCases) { Text($0.rawValue).tag($0) } }.frame(maxWidth: 240)
                Button { chooseOutput() } label: { Label(queue.outputFolder?.lastPathComponent ?? "Ausgabeordner wählen …", systemImage: "folder") }
                    .disabled(queue.running)
            }
            list
            HStack {
                Button { addFiles() } label: { Label("Dateien hinzufügen …", systemImage: "plus") }.disabled(queue.running)
                Button("Fertige entfernen") { queue.clearFinished() }.disabled(queue.running)
                Spacer()
                if queue.running {
                    Button("Abbrechen") { queue.cancel() }
                } else {
                    Button { queue.start(template: project) } label: { Label("Starten", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(queue.jobs.isEmpty || queue.outputFolder == nil || (queue.mode == .same && project.url == nil))
                }
            }
            Text("\(queue.doneCount) von \(queue.jobs.count) fertig · Szenen-Angleich, Sprach-Schnitt und Untertitel gelten nur für das einzeln geöffnete Video.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18).frame(width: 640, height: 560)
    }

    private var list: some View {
        List {
            if queue.jobs.isEmpty {
                Text("Videos hierher ziehen oder „Dateien hinzufügen“ wählen.").foregroundStyle(.secondary)
            }
            ForEach(queue.jobs) { job in
                HStack {
                    Image(systemName: icon(job.status)).foregroundStyle(color(job.status)).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.url.lastPathComponent).lineLimit(1)
                        switch job.status {
                        case .working(let p, let t): ProgressView(value: p) { Text(t).font(.caption) }
                        case .done(let u): Text("→ \(u.lastPathComponent)").font(.caption).foregroundStyle(.secondary)
                        case .failed(let m): Text(m).font(.caption).foregroundStyle(.red)
                        case .cancelled: Text("Abgebrochen").font(.caption).foregroundStyle(.secondary)
                        case .waiting: EmptyView()
                        }
                    }
                    Spacer()
                    if case .done(let u) = job.status { Button { NSWorkspace.shared.activateFileViewerSelecting([u]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless) }
                    if !queue.running { Button { queue.remove(job.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless) }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(targeted ? Color.accentColor : .clear, lineWidth: 2))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for p in providers { _ = p.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in queue.add([url]) } } } }
            return true
        }
    }

    private func icon(_ s: BatchJob.Status) -> String {
        switch s { case .waiting: "clock"; case .working: "gearshape.2"; case .done: "checkmark.circle.fill"; case .failed: "exclamationmark.triangle.fill"; case .cancelled: "slash.circle" }
    }
    private func color(_ s: BatchJob.Status) -> Color {
        switch s { case .done: .green; case .failed: .red; case .working: .accentColor; default: .secondary }
    }
    private func addFiles() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.allowedContentTypes = [.movie, .video, .audiovisualContent]
        if p.runModal() == .OK { queue.add(p.urls) }
    }
    private func chooseOutput() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.message = "Ordner für die reparierten Videos wählen"
        if p.runModal() == .OK { queue.outputFolder = p.url }
    }
}
