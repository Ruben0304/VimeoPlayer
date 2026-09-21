import SwiftUI

struct ContentView: View {
    let embedURL: URL
    @StateObject private var model: NativePlayerModel

    init(embedURL: URL) {
        self.embedURL = embedURL
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
        .task {
            await model.load()
        }
    }
}

#Preview {
    ContentView(embedURL: URL(string: "https://vimeos.net/embed-8m5djtdb04t1.html")!)
}
