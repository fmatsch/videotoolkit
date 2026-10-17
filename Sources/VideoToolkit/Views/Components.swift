import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Severity {
    var color: Color {
        switch self {
        case .ok: .green; case .info: .blue; case .mild: .yellow; case .moderate: .orange; case .severe: .red
        }
    }
}

enum FilePanels {
    @MainActor static func openVideo() -> URL? {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie, .video, .audiovisualContent, .mpeg4Movie, .quickTimeMovie]
        p.allowsMultipleSelection = false
        p.message = "Wähle ein Video zum Reparieren"
        return p.runModal() == .OK ? p.url : nil
    }
    @MainActor static func openImage() -> URL? {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = false
        p.message = "Wähle ein Referenzbild"
        return p.runModal() == .OK ? p.url : nil
    }
    @MainActor static func saveVideo(suggested: String) -> URL? {
        let p = NSSavePanel()
        p.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        p.nameFieldStringValue = suggested
        p.canCreateDirectories = true
        return p.runModal() == .OK ? p.url : nil
    }
}

struct ParamSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var neutral: Double = 0
    var format: String = "%.2f"
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(String(format: format, value)).monospacedDigit().foregroundStyle(.secondary).font(.callout)
                Button { value = neutral } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .opacity(abs(value - neutral) > 0.0001 ? 1 : 0)
                    .help("Zurücksetzen")
            }
            Slider(value: $value, in: range)
            if let help { Text(help).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    var icon: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon ?? "circle").font(.headline).labelStyle(.titleAndIcon)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Ersatz für `@State`: Mit reinen Command Line Tools steht das SwiftUI-Makro-Plugin nicht zur Verfügung,
/// daher wird `State` direkt (ohne Makro) eingewickelt. Verhalten ist identisch.
@propertyWrapper
struct LocalState<Value>: DynamicProperty {
    private let state: State<Value>
    init(wrappedValue: Value) { state = State(initialValue: wrappedValue) }
    var wrappedValue: Value {
        get { state.wrappedValue }
        nonmutating set { state.wrappedValue = newValue }
    }
    var projectedValue: Binding<Value> { state.projectedValue }
}
