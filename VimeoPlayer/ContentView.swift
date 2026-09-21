import SwiftUI

struct ContentView: View {
    @StateObject private var model = NativePlayerModel()

    var body: some View {
        Group {
            if model.useWebFallback {
                VideoWebView(url: StreamResolver.pageURL)
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
        .task {
            await model.load()
        }
    }
}

#Preview {
    ContentView()
}
