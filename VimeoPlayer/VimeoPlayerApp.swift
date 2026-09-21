import SwiftUI

@main
struct VimeoPlayerApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 720)
        .windowStyle(.hiddenTitleBar)
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}
