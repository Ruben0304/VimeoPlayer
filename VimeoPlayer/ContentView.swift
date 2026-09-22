import SwiftUI

/// Elige entre el reproductor acelerado (proxy local) y el directo (reproductor web de la fuente).
struct ContentView: View {
    let embedURL: URL
    var target: PlaybackTarget?
    @AppStorage(PlaybackMode.storageKey) private var mode = PlaybackMode.accelerated
    @AppStorage(PlaybackSettings.preferVLCKey) private var preferVLC = false

    var body: some View {
        switch mode {
        case .accelerated:
            #if os(macOS)
            if preferVLC {
                VLCStreamPlayerView(embedURL: embedURL, target: target, mode: $mode)
            } else {
                AcceleratedPlayerView(embedURL: embedURL, target: target, mode: $mode)
            }
            #else
            AcceleratedPlayerView(embedURL: embedURL, target: target, mode: $mode)
            #endif
        case .direct:
            VideoWebView(url: embedURL)
                .ignoresSafeArea()
                .autoHidingControls {
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

    init(embedURL: URL, target: PlaybackTarget?, mode: Binding<PlaybackMode>) {
        self.embedURL = embedURL
        _mode = mode
        _model = StateObject(wrappedValue: NativePlayerModel(embedURL: embedURL, target: target))
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
        // Mientras carga o si algo falla, el selector de modo queda fijo a mano;
        // con el vídeo listo se oculta como los controles nativos.
        .autoHidingControls(pinned: !model.isReady || model.playbackError != nil) { controls }
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

// MARK: - Controles que se ocultan solos

private extension View {
    func autoHidingControls<Controls: View>(
        pinned: Bool = false,
        @ViewBuilder controls: @escaping () -> Controls
    ) -> some View {
        modifier(AutoHidingControls(pinned: pinned, controls: controls))
    }
}

/// Como los controles del reproductor nativo: en Mac aparecen al mover el ratón
/// sobre el vídeo y en iOS al tocarlo; se esconden solos tras unos segundos.
private struct AutoHidingControls<Controls: View>: ViewModifier {
    var pinned: Bool
    let controls: () -> Controls

    @State private var visible = true
    @State private var hoveringControls = false
    @State private var hideTask: Task<Void, Never>?

    private var shown: Bool { pinned || visible }

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            // Simultáneo para no quitarle el toque al reproductor, que también
            // muestra u oculta sus propios controles.
            .simultaneousGesture(TapGesture().onEnded { visible ? hide() : show() })
            #endif
            .overlay(alignment: .topTrailing) {
                controls()
                    #if os(macOS)
                    .onHover { hovering in
                        hoveringControls = hovering
                        if hovering { show() } else { scheduleHide() }
                    }
                    #endif
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
            }
            #if os(macOS)
            .onContinuousHover { phase in
                switch phase {
                case .active: show()
                case .ended: if !hoveringControls { hide() }
                }
            }
            #endif
            .animation(.easeInOut(duration: 0.2), value: shown)
            .onAppear { scheduleHide() }
            .onChange(of: pinned) { if !pinned { scheduleHide() } }
            .onDisappear { hideTask?.cancel() }
    }

    private func show() {
        visible = true
        scheduleHide()
    }

    private func hide() {
        hideTask?.cancel()
        visible = false
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, !hoveringControls else { return }
            visible = false
        }
    }
}

#Preview {
    ContentView(embedURL: URL(string: "https://vimeos.net/embed-8m5djtdb04t1.html")!)
}
