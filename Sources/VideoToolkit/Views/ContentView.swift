import SwiftUI
import UniformTypeIdentifiers

enum InspectorTab: String, CaseIterable, Identifiable {
    case diagnose = "Diagnose", video = "Video", audio = "Audio", speech = "Sprache", scenes = "Szenen", reference = "Referenz", export = "Export"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .diagnose: "stethoscope"; case .video: "film"; case .audio: "waveform"
        case .speech: "text.bubble"; case .scenes: "rectangle.split.3x1"; case .reference: "photo"; case .export: "square.and.arrow.up"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var project: Project
    @LocalState private var tab: InspectorTab = .diagnose
    @LocalState private var dropTargeted = false
    @LocalState private var showBatch = false

    var tabs: [InspectorTab] {
        project.expertMode ? InspectorTab.allCases : [.diagnose, .speech, .scenes, .reference, .export]
    }

    var body: some View {
        Group {
            switch project.state {
            case .empty: WelcomeView()
            case .analyzing(let p, let text): AnalyzingView(progress: p, text: text)
            case .ready, .exporting:
                HSplitView {
                    PreviewPane(playback: project.playback).frame(minWidth: 520)
                    inspector.frame(minWidth: 360, idealWidth: 400, maxWidth: 520)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { open() } label: { Label("Öffnen", systemImage: "folder") }
            }
            ToolbarItem(placement: .principal) {
                Text(project.url?.lastPathComponent ?? "Video Toolkit").font(.headline)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showBatch = true } label: { Label("Stapel", systemImage: "square.stack.3d.down.right") }
                    .help("Mehrere Videos nacheinander verarbeiten")
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("Modus", selection: $project.expertMode) {
                    Text("Einfach").tag(false); Text("Experte").tag(true)
                }.pickerStyle(.segmented).help("Experten-Modus: alle Einstellungen selbst anpassen")
            }
        }
        .onChange(of: project.expertMode) { _, expert in
            if !expert && (tab == .video || tab == .audio) { tab = .diagnose }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in project.open(url) } }
            }
            return true
        }
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 4).padding(6).allowsHitTesting(false) } }
        .alert("Fehler", isPresented: Binding(get: { project.errorMessage != nil }, set: { if !$0 { project.errorMessage = nil } })) {
            Button("OK") { project.errorMessage = nil }
        } message: { Text(project.errorMessage ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .openVideoRequested)) { _ in open() }
        .sheet(isPresented: $showBatch) { BatchView(queue: project.batch).environmentObject(project) }
    }

    private func open() { if let u = FilePanels.openVideo() { project.open(u) } }

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("Bereich", selection: $tab) {
                ForEach(tabs) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(10)
            Divider()
            switch tab {
            case .diagnose: DiagnoseTab()
            case .video: VideoTab()
            case .audio: AudioTab()
            case .speech: SpeechTab()
            case .scenes: ScenesTab()
            case .reference: ReferenceTab()
            case .export: ExportTab()
            }
        }
        .background(.background)
        .disabled({ if case .exporting = project.state { return tab != .export }; return false }())
    }
}

extension Notification.Name { static let openVideoRequested = Notification.Name("openVideoRequested") }

struct WelcomeView: View {
    @EnvironmentObject var project: Project
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "wand.and.stars.inverse").font(.system(size: 64)).foregroundStyle(.tint)
            Text("Video Toolkit").font(.largeTitle.bold())
            Text("Schlecht aufgenommene Videos automatisch erkennen und reparieren – komplett lokal auf deinem Mac.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
            Button { if let u = FilePanels.openVideo() { project.open(u) } } label: {
                Label("Video öffnen …", systemImage: "folder").padding(.horizontal, 10)
            }.buttonStyle(.borderedProminent).controlSize(.large)
            Text("oder Datei hierher ziehen").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 24) {
                feature("sun.max", "Licht & Farbe")
                feature("gyroscope", "Stabilisieren")
                feature("waveform", "Audio & Stimme")
                feature("photo", "Referenzbild")
            }.padding(.top, 14)
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func feature(_ icon: String, _ text: String) -> some View {
        VStack(spacing: 6) { Image(systemName: icon).font(.title2); Text(text).font(.caption) }.foregroundStyle(.secondary)
    }
}

struct AnalyzingView: View {
    let progress: Double
    let text: String
    var body: some View {
        VStack(spacing: 14) {
            ProgressView(value: progress).frame(width: 280)
            Text(text).foregroundStyle(.secondary)
            Text("Das Video wird auf Belichtung, Farbe, Rauschen, Schärfe, Wackeln und Tonprobleme untersucht.")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 360)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
