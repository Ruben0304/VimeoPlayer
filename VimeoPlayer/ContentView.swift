import SwiftUI

/// Elige entre el reproductor acelerado (proxy local) y el directo (reproductor web de la fuente).
struct ContentView: View {
    let embedURL: URL
    @AppStorage(PlaybackMode.storageKey) private var mode = PlaybackMode.accelerated

    var body: some View {
        switch mode {
        case .accelerated:
            AcceleratedPlayerView(embedURL: embedURL, mode: $mode)
        case .direct:
            VideoWebView(url: embedURL)
                .ignoresSafeArea()
                .overlay(alignment: .topTrailing) {
                    ModeMenu(mode: $mode)
                        .padding(.top, controlsTopInset)
                        .padding(.trailing, 16)
                }
        }
    }
}

private let controlsTopInset: CGFloat = {
    #if os(iOS)
    56
    #else
    14
    #endif
}()

private struct AcceleratedPlayerView: View {
    let embedURL: URL
    @Binding var mode: PlaybackMode
    @StateObject private var model: NativePlayerModel

    init(embedURL: URL, mode: Binding<PlaybackMode>) {
        self.embedURL = embedURL
        _mode = mode
        _model = StateObject(wrappedValue: NativePlayerModel(embedURL: embedURL))
    }

    var body: some View {
        Group {
            if model.useWebFallback {
                VideoWebView(url: embedURL)
            } else if model.isReady {
                NativePlayerView(player: model.player)
                    .overlay(alignment: .bottom) {
                        if let error = model.playbackError {
                            Text(error)
                                .font(.caption)
                                .padding(8)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                                .padding()
                        }
                    }
            } else {
                Color.black.overlay {
                    ProgressView("Preparando reproductor…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .ignoresSafeArea()
        // El selector de modo está siempre a mano, también mientras carga o si algo falla.
        .overlay(alignment: .topTrailing) { controls }
        .task {
            await model.load()
        }
        .onDisappear {
            model.stop()
        }
    }

    // MARK: - Controles propios (calidad y buffer); audio y subtítulos usan el menú nativo

    private var controls: some View {
        HStack(spacing: 8) {
            if model.isReady, let buffer = model.buffer {
                BufferBadge(status: buffer)
            }
            if model.isReady, !model.qualities.isEmpty {
                qualityMenu
            }
            ModeMenu(mode: $mode)
        }
        .padding(.top, controlsTopInset)
        .padding(.trailing, 16)
    }

    private var qualityMenu: some View {
        Menu {
            Picker("Calidad", selection: Binding(
                get: { model.selectedQuality },
                set: { id in Task { await model.selectQuality(id) } }
            )) {
                ForEach(model.qualities) { Text($0.title).tag($0.id) }
            }
        } label: {
            Label(model.qualities.first { $0.id == model.selectedQuality }?.title ?? "Calidad",
                  systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glass(in: Capsule(), interactive: true)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// Cuánto hay ya descargado por delante y del total.
private struct BufferBadge: View {
    let status: StreamProxy.Status

    var body: some View {
        Label(text, systemImage: status.isComplete ? "checkmark.circle.fill" : "arrow.down.circle")
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glass(in: Capsule())
            .help("Buffer descargado por delante · porcentaje del título en disco")
    }

    private var text: String {
        if status.isComplete { return "Todo descargado" }
        return "\(format(status.bufferedAhead)) · \(Int(status.cachedFraction * 100)) %"
    }

    private func format(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        if minutes >= 60 { return "\(minutes / 60) h \(minutes % 60) min" }
        return minutes >= 1 ? "\(minutes) min" : "\(Int(seconds)) s"
    }
}

#Preview {
    ContentView(embedURL: URL(string: "https://vimeos.net/embed-8m5djtdb04t1.html")!)
}
