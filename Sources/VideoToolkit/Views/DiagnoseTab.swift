import SwiftUI

struct DiagnoseTab: View {
    @EnvironmentObject var project: Project

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                summary
                if !project.videoIssues.isEmpty { group("Video", icon: "film", issues: project.videoIssues) }
                if !project.audioIssues.isEmpty { group("Audio", icon: "waveform", issues: project.audioIssues) }
                if project.videoIssues.isEmpty && project.audioIssues.isEmpty {
                    SectionCard(title: "Keine Probleme erkannt", icon: "checkmark.seal") {
                        Text("Die automatische Analyse hat nichts Auffälliges gefunden. Im Expertenmodus kannst du trotzdem selbst Hand anlegen.")
                            .foregroundStyle(.secondary)
                    }
                }
                if !project.videoIssues.isEmpty || !project.audioIssues.isEmpty { intensityCard }
                metrics
            }
            .padding(14)
        }
    }

    private var summary: some View {
        let all = project.videoIssues + project.audioIssues
        let worst = all.map(\.severity).max() ?? .ok
        return HStack(spacing: 10) {
            Image(systemName: worst >= .moderate ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.title).foregroundStyle(worst == .ok ? .green : worst.color)
            VStack(alignment: .leading) {
                Text(all.isEmpty ? "Alles in Ordnung" : "\(all.count) Probleme erkannt").font(.headline)
                Text("Alles wird lokal auf diesem Mac analysiert.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !all.isEmpty {
                Menu {
                    Button("Alle Empfehlungen anwenden") { project.setAll(true) }
                    Button("Alle zurücknehmen") { project.setAll(false) }
                } label: { Text("Auswahl") }.fixedSize()
            }
        }
    }

    private func group(_ title: String, icon: String, issues: [Issue]) -> some View {
        SectionCard(title: title, icon: icon) {
            ForEach(issues) { issue in
                HStack(alignment: .top, spacing: 8) {
                    Toggle("", isOn: Binding(get: { project.isEnabled(issue.fix) },
                                             set: { project.setFix(issue.fix, enabled: $0) }))
                        .labelsHidden().toggleStyle(.checkbox)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(issue.title).font(.callout.weight(.semibold))
                            Text(issue.severity.label).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 1)
                                .background(issue.severity.color.opacity(0.25), in: Capsule())
                        }
                        Text(issue.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if issue.id != issues.last?.id { Divider() }
            }
        }
    }

    private var intensityCard: some View {
        SectionCard(title: "Stärke der Korrekturen", icon: "slider.horizontal.3") {
            ParamSlider(title: "Intensität", value: $project.intensity, range: 0...1.5, neutral: 1, format: "%.2f×",
                        help: "1× entspricht der automatischen Empfehlung. Feineinstellungen findest du im Expertenmodus.")
        }
    }

    @ViewBuilder private var metrics: some View {
        DisclosureGroup("Messwerte") {
            VStack(alignment: .leading, spacing: 4) {
                if let v = project.videoAnalysis {
                    row("Helligkeit", String(format: "%.0f %%", v.meanLuma * 100))
                    row("Tonwertumfang", String(format: "%.0f %%", (v.p99 - v.p1) * 100))
                    row("Sättigung", String(format: "%.0f %%", v.meanSaturation * 100))
                    row("Rauschen", String(format: "σ ≈ %.1f / 255", v.noiseSigma * 255))
                    row("Schärfe", String(format: "%.0f %%", v.sharpness * 100))
                    row("Wackeln", String(format: "%.2f %%", v.shakePercent))
                    row("Flackern", String(format: "%.1f %%", v.flickerPercent))
                    row("Gesichter", "\(v.faceCount)")
                }
                if let a = project.audioAnalysis {
                    Divider()
                    row("Lautheit", String(format: "%.1f LUFS", a.loudnessLUFS))
                    row("Spitzenpegel", String(format: "%.1f dBFS", a.peakDB))
                    row("Rauschteppich", String(format: "%.0f dBFS", a.noiseFloorDB))
                    row("Signal/Rauschen", String(format: "%.0f dB", a.snrDB))
                    row("Brummen", a.humHz > 0 ? "\(Int(a.humHz)) Hz" : "–")
                }
            }.padding(.top, 6)
        }
        .font(.callout)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).monospacedDigit() }.font(.caption)
    }
}
