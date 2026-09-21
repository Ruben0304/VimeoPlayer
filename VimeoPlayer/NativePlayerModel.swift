import AVFoundation
import Combine
import JavaScriptCore

@MainActor
final class NativePlayerModel: ObservableObject {
    let player = AVPlayer()
    let embedURL: URL
    @Published private(set) var isLoading = true
    @Published private(set) var isReady = false
    @Published private(set) var useWebFallback = false
    @Published private(set) var playbackError: String?
    /// Calidades disponibles; vacío si el título solo tiene una.
    @Published private(set) var qualities: [QualityOption] = []
    @Published private(set) var selectedQuality = QualityOption.automatic.id
    @Published private(set) var buffer: StreamProxy.Status?

    private var proxy: StreamProxy?
    private var statusTask: Task<Void, Never>?
    private var itemStatus: AnyCancellable?
    private var hasStartedPlaying = false

    private let progress: WatchProgressReporter?

    init(embedURL: URL, target: PlaybackTarget? = nil) {
        self.embedURL = embedURL
        progress = WatchProgressReporter(target: target)
    }

    func load() async {
        do {
            let stream = try await StreamResolver.resolve(from: embedURL)
            let proxy = try await StreamProxy.start(masterURL: stream.masterURL, subtitles: stream.subtitles)
            guard !Task.isCancelled else {
                await proxy.stop()
                return
            }
            self.proxy = proxy
            qualities = proxy.qualities
            player.replaceCurrentItem(with: await makeItem(quality: nil))
            if let resume = progress?.resumePosition {
                await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            isReady = true
            player.play()
            startStatusUpdates()
        } catch {
            // Si el origen cambia su formato, el reproductor web sigue siendo un respaldo
            // en lugar de dejar la pantalla en blanco.
            useWebFallback = true
        }
        isLoading = false
    }

    /// Detiene la reproducción y la descarga en segundo plano, y borra la caché de disco.
    func stop() {
        saveProgress(force: true)
        statusTask?.cancel()
        statusTask = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        let proxy = self.proxy
        self.proxy = nil
        Task { await proxy?.stop() }
    }

    /// Cambia de calidad en el mismo punto, conservando el audio y los subtítulos elegidos.
    func selectQuality(_ id: QualityOption.ID) async {
        guard isReady, id != selectedQuality, let option = qualities.first(where: { $0.id == id }) else { return }
        selectedQuality = id

        let time = player.currentTime()
        let wasPlaying = player.timeControlStatus != .paused
        let audio = await selectedName(.audible, in: player.currentItem)
        let subtitles = await selectedName(.legible, in: player.currentItem)

        let item = await makeItem(quality: option.variant)
        player.replaceCurrentItem(with: item)
        await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        await select(name: audio, characteristic: .audible, in: item)
        await select(name: subtitles, characteristic: .legible, in: item)
        if wasPlaying { player.play() }
    }

    // MARK: - Interno

    private func makeItem(quality: Int?) async -> AVPlayerItem {
        let url = await proxy!.masterURL(quality: quality)
        let item = AVPlayerItem(url: url)
        // El grueso del buffer vive en disco (StreamProxy); en memoria basta un margen amplio.
        item.preferredForwardBufferDuration = 120

        itemStatus = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    hasStartedPlaying = true
                case .failed:
                    playbackError = item.error?.localizedDescription ?? "El reproductor local no pudo leer el stream."
                    if !hasStartedPlaying { useWebFallback = true }
                default:
                    break
                }
            }
        return item
    }

    private func selectedName(_ characteristic: AVMediaCharacteristic, in item: AVPlayerItem?) async -> String? {
        guard let item, let group = try? await item.asset.loadMediaSelectionGroup(for: characteristic) else { return nil }
        return item.currentMediaSelection.selectedMediaOption(in: group)?.displayName
    }

    private func select(name: String?, characteristic: AVMediaCharacteristic, in item: AVPlayerItem) async {
        guard let name, let group = try? await item.asset.loadMediaSelectionGroup(for: characteristic),
              let option = group.options.first(where: { $0.displayName == name }) else { return }
        item.select(option, in: group)
    }

    private func saveProgress(force: Bool = false) {
        guard let item = player.currentItem else { return }
        progress?.report(position: player.currentTime().seconds, duration: item.duration.seconds, force: force)
    }

    private func startStatusUpdates() {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let proxy = self.proxy else { return }
                let time = self.player.currentTime().seconds
                self.buffer = await proxy.status(at: time.isFinite ? time : 0)
                self.saveProgress()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

extension QualityOption {
    static let automatic = QualityOption(variant: nil, title: "Automática")
}

struct ResolvedStream {
    let masterURL: URL
    let subtitles: [SubtitleTrack]
}

enum StreamResolver {
    static func resolve(from pageURL: URL) async throws -> ResolvedStream {
        // El token del stream va ligado al cliente que pidió la página: mismo User-Agent que en el CDN.
        var request = URLRequest(url: pageURL)
        request.setValue(SegmentDownloader.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
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

        let sourcePattern = #"sources\s*:\s*\[\s*\{\s*file\s*:\s*[\"']([^\"']+)"#
        guard let source = firstMatch(sourcePattern, in: unpacked)?.first, let masterURL = URL(string: source) else {
            throw URLError(.cannotParseResponse)
        }

        // Subtítulos externos (.vtt) que el reproductor web ofrece; el "empty.srt" es un marcador.
        let trackPattern = #"\{\s*file\s*:\s*[\"']([^\"']+\.vtt[^\"']*)[\"']\s*,\s*label\s*:\s*[\"']([^\"']*)[\"']"#
        let subtitles = matches(trackPattern, in: unpacked).compactMap { groups -> SubtitleTrack? in
            guard groups.count == 2, let url = URL(string: groups[0], relativeTo: pageURL)?.absoluteURL else { return nil }
            let (name, language) = describe(subtitleLabel: groups[1])
            return SubtitleTrack(name: name, language: language, url: url)
        }
        return ResolvedStream(masterURL: masterURL, subtitles: subtitles)
    }

    private static let languages: [String: (name: String, code: String)] = [
        "spanish": ("Español", "es"), "english": ("Inglés", "en"), "portuguese": ("Portugués", "pt"),
        "french": ("Francés", "fr"), "italian": ("Italiano", "it"), "german": ("Alemán", "de"),
    ]

    private static func describe(subtitleLabel label: String) -> (name: String, language: String?) {
        guard let language = languages[label.lowercased()] else { return (label, nil) }
        return (language.name, language.code)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        matches(pattern, in: text).first
    }

    /// Todas las coincidencias, cada una como la lista de sus grupos capturados.
    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        }
    }
}
