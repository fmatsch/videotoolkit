import SwiftUI

struct PreviewPane: View {
    @EnvironmentObject var project: Project
    @LocalState private var split: CGFloat = 0.5

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if project.hasVideo {
                    compareView
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

    @ViewBuilder private var compareView: some View {
        GeometryReader { geo in
            ZStack {
                if let before = project.beforeImage {
                    let after = project.afterImage ?? before
                    switch project.compare {
                    case .before: image(before)
                    case .after: image(after)
                    case .split:
                        image(after)
                        image(before).mask(alignment: .leading) {
                            Rectangle().frame(width: geo.size.width * split)
                        }
                        Rectangle().fill(.white).frame(width: 2).shadow(radius: 2)
                            .position(x: geo.size.width * split, y: geo.size.height / 2)
                        Image(systemName: "arrow.left.and.right.circle.fill").font(.title).foregroundStyle(.white).shadow(radius: 3)
                            .position(x: geo.size.width * split, y: geo.size.height / 2)
                        label("Vorher").position(x: 44, y: 18)
                        label("Nachher").position(x: geo.size.width - 48, y: 18)
                    }
                } else {
                    ProgressView()
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard project.compare == .split else { return }
                split = min(1, max(0, g.location.x / geo.size.width))
            })
        }
    }

    private func image(_ cg: CGImage) -> some View {
        Image(decorative: cg, scale: 1).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule()).foregroundStyle(.white)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            if project.hasVideo {
                HStack {
                    Text(Project.format(project.previewTime)).monospacedDigit().font(.caption)
                    Slider(value: $project.previewTime, in: 0...max(0.1, project.duration - 0.1))
                    Text(Project.format(project.duration)).monospacedDigit().font(.caption)
                }
            }
            HStack {
                if let v = project.videoAnalysis {
                    Text(String(format: "%d×%d · %.0f fps · %@", v.width, v.height, v.fps, Project.format(v.duration)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
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
