import SwiftUI

/// Busca las fuentes del título y abre el reproductor con la mejor disponible.
struct PlayerLoaderView: View {
    let target: PlaybackTarget

    @State private var embedURL: URL?
    @State private var failed = false

    var body: some View {
        Group {
            if let embedURL {
                ContentView(embedURL: embedURL)
            } else if failed {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text("No se encontró una fuente para reproducir").font(.headline)
                    Button("Reintentar") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Buscando fuente…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
        .navigationTitle(target.title)
        .task { await load() }
    }

    private func load() async {
        failed = false
        do {
            embedURL = Self.bestEmbed(in: try await LaMovieAPI.embeds(postId: target.postId))
            failed = embedURL == nil
        } catch {
            failed = true
        }
    }

    /// El reproductor nativo sabe leer vimeos.net; para otros servidores el
    /// reproductor cae al modo web, que puede reproducir cualquier embed.
    private static func bestEmbed(in embeds: [Embed]) -> URL? {
        let preferred = embeds.first { $0.host?.hasSuffix("vimeos.net") == true } ?? embeds.first
        return preferred.flatMap { URL(string: $0.url) }
    }
}

// MARK: - Modo de reproducción

/// Acelerado: proxy local (calidad, audio, subtítulos y buffer). Directo: reproductor web original
/// de la fuente, por si el proxy no carga un título.
enum PlaybackMode: String, CaseIterable, Identifiable {
    case accelerated, direct

    static let storageKey = "playbackMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accelerated: "Acelerado"
        case .direct: "Directo"
        }
    }

    var detail: String {
        switch self {
        case .accelerated: "Proxy local: calidad, audio, subtítulos y buffer"
        case .direct: "Reproductor web original de la fuente"
        }
    }

    var systemImage: String {
        switch self {
        case .accelerated: "bolt.fill"
        case .direct: "arrow.right.circle"
        }
    }
}

/// Selector Acelerado / Directo; el cambio recarga el título con el modo elegido.
struct ModeMenu: View {
    @Binding var mode: PlaybackMode

    var body: some View {
        Menu {
            Picker("Modo", selection: $mode) {
                ForEach(PlaybackMode.allCases) { option in
                    Label {
                        Text("\(option.title) · \(option.detail)")
                    } icon: {
                        Image(systemName: option.systemImage)
                    }
                    .tag(option)
                }
            }
        } label: {
            Label(mode.title, systemImage: mode.systemImage)
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

// MARK: - Presentación a pantalla completa

/// Qué título se está reproduciendo. En Mac lo lee la ventana "Reproductor"; en iOS, la cubierta
/// a pantalla completa.
@MainActor
final class PlaybackCoordinator: ObservableObject {
    static let windowID = "player"

    @Published var target: PlaybackTarget?
}

/// Botón que abre el reproductor a pantalla completa (ventana propia en Mac, `fullScreenCover` en iOS).
struct PlayButton<Label: View>: View {
    let target: PlaybackTarget
    @ViewBuilder let label: () -> Label

    @EnvironmentObject private var coordinator: PlaybackCoordinator
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        Button {
            coordinator.target = target
            #if os(macOS)
            openWindow(id: PlaybackCoordinator.windowID)
            #endif
        } label: {
            label()
        }
    }
}

#if os(macOS)
import AppKit

/// Contenido de la ventana "Reproductor": sin barra de título ni botón de volver; la pantalla
/// completa es la nativa de macOS (botón verde), y Esc sale de ella o cierra la ventana.
struct PlayerWindowHost: View {
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @State private var window: NSWindow?
    @State private var isFullScreen = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let target = coordinator.target {
                if let page = target.mediaFire {
                    RARPlayerView(target: target, pageURL: page).id(target.id)
                } else {
                    PlayerLoaderView(target: target).id(target.id)
                }
            }
        }
        .ignoresSafeArea()
        .background(WindowAccessor { found in
            guard let found, window !== found else { return }
            found.collectionBehavior.insert(.fullScreenPrimary)
            found.titlebarAppearsTransparent = true
            found.titleVisibility = .hidden
            found.isMovableByWindowBackground = true
            found.backgroundColor = .black
            window = found
            isFullScreen = found.styleMask.contains(.fullScreen)
        })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            if (note.object as? NSWindow) === window { isFullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if (note.object as? NSWindow) === window { isFullScreen = false }
        }
        .onExitCommand {
            if isFullScreen { window?.toggleFullScreen(nil) } else { window?.close() }
        }
        // Cerrar con el semáforo o ⌘W también cuenta como dejar de reproducir.
        .onDisappear { coordinator.target = nil }
    }
}

/// Da acceso a la `NSWindow` que contiene la vista.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(view.window) }
    }
}
#else
/// Cubierta a pantalla completa (iOS): sin barra de navegación, con botón de cerrar.
struct PlayerCover: View {
    let target: PlaybackTarget

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            PlayerLoaderView(target: target)
            Button { dismiss() } label: { GlassIconLabel(systemImage: "xmark", size: 40) }
                .buttonStyle(.plain)
                .padding(.leading, 16)
                .padding(.top, 8)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
    }
}
#endif
