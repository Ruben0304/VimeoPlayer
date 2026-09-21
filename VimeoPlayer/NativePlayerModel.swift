import AVFoundation
import JavaScriptCore

@MainActor
final class NativePlayerModel: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var isLoading = true
    @Published private(set) var isReady = false
    @Published private(set) var useWebFallback = false
    @Published private(set) var playbackError: String?

    func load() async {
        do {
            let streamURL = try await StreamResolver.resolveStreamURL()
            let item = AVPlayerItem(url: streamURL)
            player.replaceCurrentItem(with: item)
            NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] notification in
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                Task { @MainActor in self?.playbackError = error?.localizedDescription ?? "El reproductor local no pudo leer el stream." }
            }
            isReady = true
            player.play()
        } catch {
            // The source page can change its temporary-token format. The web
            // view remains a compatibility fallback rather than leaving a blank player.
            useWebFallback = true
        }
        isLoading = false
    }
}

enum StreamResolver {
    static let pageURL = URL(string: "https://vimeos.net/embed-8m5djtdb04t1.html")!

    static func resolveStreamURL() async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: pageURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              let page = String(data: data, encoding: .utf8) else {
            throw URLError(.badServerResponse)
        }

        // The page wraps the player configuration in a P.A.C.K.E.R. script.
        // Evaluate only its unpacking function: the decoded player script is
        // returned as text and is never executed in the app.
        guard let scriptStart = page.range(of: "eval(function"),
              let scriptEnd = page.range(of: "</script>", range: scriptStart.lowerBound..<page.endIndex) else {
            throw URLError(.cannotParseResponse)
        }
        let packedScript = String(page[scriptStart.lowerBound..<scriptEnd.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard packedScript.hasPrefix("eval("), packedScript.hasSuffix(")") else {
            throw URLError(.cannotParseResponse)
        }

        let unpackerExpression = "(" + packedScript.dropFirst(5).dropLast() + ")"
        guard let unpacked = JSContext()?.evaluateScript(unpackerExpression)?.toString() else {
            throw URLError(.cannotDecodeContentData)
        }

        let pattern = #"sources\s*:\s*\[\s*\{\s*file\s*:\s*[\"']([^\"']+)"#
        let range = NSRange(unpacked.startIndex..., in: unpacked)
        guard let match = try NSRegularExpression(pattern: pattern).firstMatch(in: unpacked, range: range),
              let streamRange = Range(match.range(at: 1), in: unpacked),
              let streamURL = URL(string: String(unpacked[streamRange])) else {
            throw URLError(.cannotParseResponse)
        }

        return streamURL
    }
}
