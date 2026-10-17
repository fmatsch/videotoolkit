import SwiftUI

struct PreviewPane: View {
    @EnvironmentObject var project: Project
    @ObservedObject var playback: PlaybackController

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if project.hasVideo {
                    videoArea
                } else if project.hasAudio {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform").font(.system(size: 54)).foregroundStyle(.secondary)
                        Text("Reine Audiodatei – Anpassungen im Tab „Audio“ (Expertenmodus) oder in der Diagnose.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding()
                }
            }
            controls
        }
    }

    private var videoArea: some View {
        GeometryReader { geo in
            ZStack {
                PlayerView(player: playback.player)
                if project.compare == .split {
                    let x = geo.size.width * project.splitFraction
                    Rectangle().fill(.white).frame(width: 2).shadow(radius: 2).position(x: x, y: geo.size.height / 2)
                    Image(systemName: "arrow.left.and.right.circle.fill").font(.title).foregroundStyle(.white).shadow(radius: 3)
                        .position(x: x, y: geo.size.height / 2)
                    label("Vorher").position(x: 44, y: 18)
                    label("Nachher").position(x: geo.size.width - 48, y: 18)
                } else {
                    label(project.compare == .before ? "Vorher" : "Nachher").position(x: 48, y: 18)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard project.compare == .split else { return }
                project.splitFraction = min(1, max(0, g.location.x / geo.size.width))
            })
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule()).foregroundStyle(.white)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            if project.hasVideo || project.hasAudio {
                HStack(spacing: 10) {
                    Button { playback.togglePlay() } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    .help("Abspielen / Anhalten (Leertaste)")
                    Button { playback.step(frames: -1, fps: project.videoAnalysis?.fps ?? 30) } label: { Image(systemName: "backward.frame.fill") }
                        .buttonStyle(.borderless).help("Ein Bild zurück")
                    Button { playback.step(frames: 1, fps: project.videoAnalysis?.fps ?? 30) } label: { Image(systemName: "forward.frame.fill") }
                        .buttonStyle(.borderless).help("Ein Bild vor")
                    Text(Project.format(playback.currentTime)).monospacedDigit().font(.caption)
                    Slider(value: Binding(get: { playback.currentTime }, set: { project.seek(to: $0) }),
                           in: 0...max(0.1, playback.duration))
                    Text(Project.format(playback.duration)).monospacedDigit().font(.caption)
                }
            }
            HStack {
                if let v = project.videoAnalysis {
                    Text(String(format: "%d×%d · %.0f fps", v.width, v.height, v.fps)).font(.caption).foregroundStyle(.secondary)
                }
                if let status = playback.audioStatus {
                    ProgressView().controlSize(.small)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if project.hasAudio {
                    Toggle(isOn: Binding(get: { playback.useProcessedAudio }, set: { project.setLiveProcessedAudio($0) })) {
                        Image(systemName: playback.useProcessedAudio ? "speaker.wave.2.fill" : "speaker.wave.2")
                    }
                    .toggleStyle(.button).help("Bearbeiteten Ton abspielen (wird beim ersten Mal berechnet)")
                }
                if project.hasVideo {
                    Picker("Vergleich", selection: $project.compare) {
                        ForEach(CompareMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
            }
            if project.video.denoiseTemporal > 0 || project.video.upscale > 1 {
                Text("Hinweis: Zeitliche Entrauschung und Hochskalierung sind erst im Export sichtbar.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(.bar)
    }
}
