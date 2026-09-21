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

        // El reproductor va en su propia ventana, sin barra de título, para que la pantalla completa sea total.
        Window("Reproductor", id: PlaybackCoordinator.windowID) {
            PlayerWindowHost()
                .environmentObject(coordinator)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)
        #else
        WindowGroup {
            HomeView()
                .environmentObject(coordinator)
        }
        #endif
    }
}
