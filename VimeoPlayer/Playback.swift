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
