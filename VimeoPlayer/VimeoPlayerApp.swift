import SwiftUI

@main
struct VimeoPlayerApp: App {
    @StateObject private var coordinator = PlaybackCoordinator()

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            HomeView()
                .environmentObject(coordinator)
        }
        .defaultSize(width: 1280, height: 720)
        .windowStyle(.hiddenTitleBar)
        // Mantiene toolbar y titlebar en una sola franja, pero con la altura
        // estándar de macOS para alinear los controles con los semáforos.
        .windowToolbarStyle(.unified(showsTitle: false))

        // El reproductor va en su propia ventana, sin barra de título, para que la pantalla completa sea total.
        Window("Reproductor", id: PlaybackCoordinator.windowID) {
            PlayerWindowHost()
                .environmentObject(coordinator)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)

        Settings {
            TabView {
                SettingsView()
                    .tabItem { Label("TMDB", systemImage: "photo") }
                PlayerSettingsView()
                    .tabItem { Label("Reproductor", systemImage: "play.rectangle") }
            }
        }
        #else
        WindowGroup {
            HomeView()
                .environmentObject(coordinator)
        }
        #endif
    }
}
