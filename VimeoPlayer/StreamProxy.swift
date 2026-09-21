import Foundation

struct SubtitleTrack: Sendable {
    let name: String
    let language: String?
    let url: URL
}

struct QualityOption: Identifiable, Hashable, Sendable {
    /// Índice de la variante; `nil` es "Automática" (AVPlayer elige).
    let variant: Int?
    let title: String

    var id: Int { variant ?? -1 }
}

/// Proxy HLS local para un VOD de vimeos.
///
/// AVPlayer no puede hablar directo con el CDN (responde 403 a su User-Agent), así que esto le
/// sirve el stream desde 127.0.0.1 y hace de intermediario:
/// - descarga por carriles (`SegmentDownloader`) con User-Agent de navegador y guarda cada segmento
///   en disco;
/// - **calidad**: publica un master con la variante elegida (o todas);
/// - **audio**: pasa las pistas de audio del HLS, que el reproductor muestra en su menú;
/// - **subtítulos**: los `.vtt` externos de la web se anuncian como pista de subtítulos HLS;
/// - **buffer**: además de servir lo que AVPlayer pide, precarga en segundo plano desde la
///   posición actual hasta el final (y luego lo anterior), con un tope de disco. El ancho de banda
///   del CDN es limitado (más conexiones no suman), así que la precarga cede ante la reproducción:
///   no arranca hasta que hay colchón, y se cancela al saltar a otro punto.
actor StreamProxy {
    struct Status: Equatable, Sendable {
        /// Segundos ya descargados por delante de la posición actual.
        var bufferedAhead: Double
        /// Fracción del título descargada en disco (0...1).
        var cachedFraction: Double
        var cachedBytes: Int
        var isComplete: Bool
    }

    private enum Track: Hashable {
        case video(Int)
        case audio(Int)
    }

    private struct Key: Hashable {
        let track: Track
        let index: Int
    }

    /// Tope de disco de la precarga.
    static let maxCacheBytes = 4 * 1024 * 1024 * 1024

    nonisolated let qualities: [QualityOption]
    nonisolated let duration: Double

    private let master: HLS.Master
    private let videoPlaylists: [HLS.MediaPlaylist]
    private let audioPlaylists: [HLS.MediaPlaylist]
    private let subtitles: [SubtitleTrack]
    private let downloader: SegmentDownloader
    private let server = LocalHTTPServer()
    private let directory: URL

    private var port: UInt16 = 0
    private var cached = Set<Key>()
    private var inFlight: [Key: Task<Void, Error>] = [:]
    private var failures: [Key: Int] = [:]
    private var cachedBytes = 0
    private var activeVideo: Int
    private var activeAudio: Int?
    private var playhead = 0
    private var playbackTime = 0.0
    /// Claves que AVPlayer está esperando ahora mismo; la precarga no las cancela.
    private var demanded = Set<Key>()
    private var subtitleCache: [Int: Data] = [:]
    private var videoStartPTS: Int?
    private var workers: [Task<Void, Never>] = []
    private var stopped = false

    // MARK: - Arranque

    static func start(masterURL: URL, subtitles: [SubtitleTrack]) async throws -> StreamProxy {
        removeStaleDirectories()
        let downloader = SegmentDownloader()
        do {
            let master = try HLS.parseMaster(try await downloader.text(from: masterURL), baseURL: masterURL)
            async let videos = loadPlaylists(master.variants.map(\.url), downloader)
            async let audios = loadPlaylists(master.audio.map(\.url), downloader)
            let proxy = StreamProxy(master: master, videos: try await videos, audios: try await audios,
                                    subtitles: subtitles, downloader: downloader)
            try await proxy.startServing()
            return proxy
        } catch {
            downloader.invalidate()
            throw error
        }
    }

    private init(master: HLS.Master, videos: [HLS.MediaPlaylist], audios: [HLS.MediaPlaylist],
                 subtitles: [SubtitleTrack], downloader: SegmentDownloader) {
        self.master = master
        self.videoPlaylists = videos
        self.audioPlaylists = audios
        self.subtitles = subtitles
        self.downloader = downloader
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VimeoPlayer-stream-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        duration = videos.last?.totalDuration ?? 0
        activeVideo = master.variants.count - 1
        activeAudio = (master.audio.first { $0.isDefault } ?? master.audio.first)?.index

        var options: [QualityOption] = []
        if master.variants.count > 1 {
            options.append(QualityOption(variant: nil, title: "Automática"))
            options += master.variants.reversed().map { QualityOption(variant: $0.index, title: Self.title(for: $0)) }
        }
        qualities = options
    }

    private static func title(for variant: HLS.Variant) -> String {
        guard variant.height > 0 else { return "\(variant.bandwidth / 1000) kbps" }
        return variant.height >= 720 ? "\(variant.height)p HD" : "\(variant.height)p"
    }

    private static func loadPlaylists(_ urls: [URL], _ downloader: SegmentDownloader) async throws -> [HLS.MediaPlaylist] {
        try await withThrowingTaskGroup(of: (Int, HLS.MediaPlaylist).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    (index, try HLS.parseMedia(try await downloader.text(from: url), baseURL: url))
                }
            }
            var result: [(Int, HLS.MediaPlaylist)] = []
            for try await item in group { result.append(item) }
            return result.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func startServing() async throws {
        port = try await server.start { [weak self] path in await self?.handle(path) }
        for lane in 1...SegmentDownloader.prefetchLanes {
            workers.append(Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    if await !self.prefetchStep(lane: lane) { try? await Task.sleep(for: .seconds(1)) }
                }
            })
        }
    }

    /// URL que se le da a AVPlayer. `quality` es un índice de variante; `nil`, automática.
    func masterURL(quality: Int?) -> URL {
        URL(string: "http://127.0.0.1:\(port)/master-\(quality.map(String.init) ?? "auto").m3u8")!
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        workers.forEach { $0.cancel() }
        workers = []
        inFlight.values.forEach { $0.cancel() }
        server.stop()
        downloader.invalidate()
        try? FileManager.default.removeItem(at: directory)
    }

    private static func removeStaleDirectories() {
        let temp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
        for name in names where name.hasPrefix("VimeoPlayer-") {
            try? FileManager.default.removeItem(at: temp.appendingPathComponent(name))
        }
    }

    // MARK: - Estado

    /// Cuánto hay descargado, respecto a la posición de reproducción `time` (segundos).
    /// Al consultarlo se registra esa posición, que la precarga usa para decidir cuánto puede descargar.
    func status(at time: Double) -> Status {
        playbackTime = time
        let segments = videoPlaylists[activeVideo].segments
        let audioCount = activeAudio.map { audioPlaylists[$0].segments.count } ?? 0
        let total = segments.count + audioCount
        let have = (0..<segments.count).filter { cached.contains(Key(track: .video(activeVideo), index: $0)) }.count
            + (activeAudio.map { audio in (0..<audioCount).filter { cached.contains(Key(track: .audio(audio), index: $0)) }.count } ?? 0)
        let fraction = total == 0 ? 0 : Double(have) / Double(total)
        return Status(bufferedAhead: aheadSeconds(from: time), cachedFraction: fraction,
                      cachedBytes: cachedBytes, isComplete: total > 0 && have == total)
    }

    /// Segundos de vídeo (con su audio) ya en disco, contiguos, a partir de `time`.
    private func aheadSeconds(from time: Double) -> Double {
        let segments = videoPlaylists[activeVideo].segments
        var start = 0.0
        var index = segments.count
        for (i, segment) in segments.enumerated() {
            if start + segment.duration > time { index = i; break }
            start += segment.duration
        }
        var ahead = 0.0
        var i = index
        while i < segments.count, isCached(at: i) {
            ahead += i == index ? start + segments[i].duration - time : segments[i].duration
            i += 1
        }
        return ahead
    }

    private func isCached(at index: Int) -> Bool {
        guard cached.contains(Key(track: .video(activeVideo), index: index)) else { return false }
        guard let audio = activeAudio, index < audioPlaylists[audio].segments.count else { return true }
        return cached.contains(Key(track: .audio(audio), index: index))
    }

    // MARK: - Peticiones de AVPlayer

    private func handle(_ path: String) async -> LocalHTTPServer.Response? {
        guard !stopped else { return nil }
        let parts = path.split(separator: "/").map(String.init)

        switch parts.count {
        case 1:
            guard parts[0].hasPrefix("master-"), parts[0].hasSuffix(".m3u8") else { return nil }
            let token = parts[0].dropFirst("master-".count).dropLast(".m3u8".count)
            let quality = Int(token)
            if let quality {
                guard master.variants.indices.contains(quality) else { return nil }
                activeVideo = quality
            } else {
                activeVideo = master.variants.count - 1
            }
            return .playlist(masterText(quality: quality))

        case 2:
            guard let (index, ext) = Self.indexAndExtension(parts[1]) else { return nil }
            switch (parts[0], ext) {
            case ("v", "m3u8") where videoPlaylists.indices.contains(index):
                return .playlist(mediaText(videoPlaylists[index], prefix: "/v/\(index)"))
            case ("a", "m3u8") where audioPlaylists.indices.contains(index):
                return .playlist(mediaText(audioPlaylists[index], prefix: "/a/\(index)"))
            case ("s", "m3u8") where subtitles.indices.contains(index):
                return .playlist(subtitlePlaylist(index))
            case ("s", "vtt") where subtitles.indices.contains(index):
                guard let data = await subtitleData(index) else { return nil }
                return .init(contentType: "text/vtt; charset=utf-8", body: data)
            default:
                return nil
            }

        case 3:
            guard let track = Int(parts[1]), let (index, ext) = Self.indexAndExtension(parts[2]), ext == "ts" else { return nil }
            let key: Key
            switch parts[0] {
            case "v" where videoPlaylists.indices.contains(track) && index < videoPlaylists[track].segments.count:
                key = Key(track: .video(track), index: index)
                activeVideo = track
                playhead = index
            case "a" where audioPlaylists.indices.contains(track) && index < audioPlaylists[track].segments.count:
                key = Key(track: .audio(track), index: index)
                activeAudio = track
            default:
                return nil
            }
            // Un salto (segmento que ni está ni se está bajando): lo primero es ese segmento.
            if !cached.contains(key), inFlight[key] == nil { cancelPrefetch(except: key) }
            demanded.insert(key)
            defer { demanded.remove(key) }
            do { try await ensure(key, lane: SegmentDownloader.demandLane) } catch { return nil }
            guard let data = try? Data(contentsOf: fileURL(for: key)) else { return nil }
            return .init(contentType: "video/mp2t", body: data)

        default:
            return nil
        }
    }

    private static func indexAndExtension(_ file: String) -> (Int, String)? {
        guard let dot = file.lastIndex(of: "."), let index = Int(file[..<dot]) else { return nil }
        return (index, String(file[file.index(after: dot)...]))
    }

    // MARK: - Playlists

    private func masterText(quality: Int?) -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-INDEPENDENT-SEGMENTS"]
        let hasDefault = master.audio.contains { $0.isDefault }
        for track in master.audio {
            var attrs = "TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"\(track.name)\""
            if let language = track.language { attrs += ",LANGUAGE=\"\(language)\"" }
            let isDefault = track.isDefault || (!hasDefault && track.index == 0)
            attrs += ",AUTOSELECT=YES,DEFAULT=\(isDefault ? "YES" : "NO")"
            if let channels = track.channels { attrs += ",CHANNELS=\"\(channels)\"" }
            lines.append("#EXT-X-MEDIA:\(attrs),URI=\"/a/\(track.index).m3u8\"")
        }
        for (index, track) in subtitles.enumerated() {
            var attrs = "TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"\(track.name)\""
            if let language = track.language { attrs += ",LANGUAGE=\"\(language)\"" }
            lines.append("#EXT-X-MEDIA:\(attrs),AUTOSELECT=NO,DEFAULT=NO,FORCED=NO,URI=\"/s/\(index).m3u8\"")
        }
        var shown = master.variants
        if let quality { shown = master.variants.filter { $0.index == quality } }
        for variant in shown {
            var attrs = "BANDWIDTH=\(variant.bandwidth)"
            if variant.height > 0 { attrs += ",RESOLUTION=\(variant.width)x\(variant.height)" }
            if let codecs = variant.codecs { attrs += ",CODECS=\"\(codecs)\"" }
            if let rate = variant.frameRate { attrs += ",FRAME-RATE=\(rate)" }
            if !master.audio.isEmpty { attrs += ",AUDIO=\"audio\"" }
            if !subtitles.isEmpty { attrs += ",SUBTITLES=\"subs\"" }
            lines += ["#EXT-X-STREAM-INF:\(attrs)", "/v/\(variant.index).m3u8"]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// El playlist se publica completo (VOD): AVPlayer puede saltar a cualquier punto y cada
    /// segmento se descarga cuando se pide.
    private func mediaText(_ playlist: HLS.MediaPlaylist, prefix: String) -> String {
        let target = Int((playlist.segments.map(\.duration).max() ?? 10).rounded(.up))
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:\(target)",
                     "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD"]
        for (index, segment) in playlist.segments.enumerated() {
            lines.append("#EXTINF:\(String(format: "%.3f", segment.duration)),")
            lines.append("\(prefix)/\(index).ts")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Los subtítulos de la web son un único `.vtt` para toda la película: se anuncian como un
    /// playlist HLS de un solo segmento.
    private func subtitlePlaylist(_ index: Int) -> String {
        """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:\(Int(duration.rounded(.up)))
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:\(String(format: "%.3f", duration)),
        /s/\(index).vtt
        #EXT-X-ENDLIST

        """
    }

    /// El `.vtt` de la web usa tiempo de película; HLS lo alinea con el vídeo mediante
    /// `X-TIMESTAMP-MAP`, con el PTS con el que arranca el primer segmento.
    private func subtitleData(_ index: Int) async -> Data? {
        if let data = subtitleCache[index] { return data }
        guard let raw = try? await downloader.data(from: subtitles[index].url, lane: SegmentDownloader.demandLane),
              var text = String(data: raw, encoding: .utf8) else { return nil }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        if !text.contains("X-TIMESTAMP-MAP"), let newline = text.firstIndex(of: "\n") {
            let pts = await firstVideoPTS()
            text.insert(contentsOf: "\nX-TIMESTAMP-MAP=MPEGTS:\(pts),LOCAL:00:00:00.000", at: newline)
        }
        let data = Data(text.utf8)
        subtitleCache[index] = data
        return data
    }

    private func firstVideoPTS() async -> Int {
        if let videoStartPTS { return videoStartPTS }
        let key = Key(track: .video(activeVideo), index: 0)
        try? await ensure(key, lane: SegmentDownloader.demandLane)
        let pts = (try? Data(contentsOf: fileURL(for: key))).flatMap(Self.firstVideoPTS(in:)) ?? 0
        videoStartPTS = pts
        return pts
    }

    /// PTS (90 kHz) del primer paquete PES de vídeo de un segmento MPEG-TS.
    static func firstVideoPTS(in data: Data) -> Int? {
        let bytes = [UInt8](data.prefix(188 * 400))
        var i = 0
        while i + 188 <= bytes.count {
            if bytes[i] == 0x47 {
                let payloadStart = bytes[i + 1] & 0x40 != 0
                let adaptation = (bytes[i + 3] >> 4) & 3
                var offset = i + 4
                if adaptation & 2 != 0 { offset += 1 + Int(bytes[i + 4]) }
                if payloadStart, adaptation & 1 != 0, offset + 14 <= i + 188,
                   bytes[offset] == 0, bytes[offset + 1] == 0, bytes[offset + 2] == 1,
                   (0xE0...0xEF).contains(bytes[offset + 3]), bytes[offset + 7] & 0x80 != 0 {
                    let b = bytes[(offset + 9)..<(offset + 14)].map(Int.init)
                    return ((b[0] >> 1) & 7) << 30 | b[1] << 22 | (b[2] >> 1) << 15 | b[3] << 7 | (b[4] >> 1)
                }
            }
            i += 188
        }
        return nil
    }

    // MARK: - Segmentos

    private func remoteURL(for key: Key) -> URL {
        switch key.track {
        case .video(let variant): videoPlaylists[variant].segments[key.index].url
        case .audio(let track): audioPlaylists[track].segments[key.index].url
        }
    }

    private func fileURL(for key: Key) -> URL {
        switch key.track {
        case .video(let variant): directory.appendingPathComponent("v\(variant)-\(key.index).ts")
        case .audio(let track): directory.appendingPathComponent("a\(track)-\(key.index).ts")
        }
    }

    /// Deja el segmento en disco: ya está, ya se está bajando (se espera a esa descarga) o se baja ahora.
    private func ensure(_ key: Key, lane: Int) async throws {
        if cached.contains(key) { return }
        if let task = inFlight[key] {
            try await task.value
            return
        }
        let url = remoteURL(for: key)
        let file = fileURL(for: key)
        let downloader = self.downloader
        let task = Task { [weak self] in
            do {
                let data = try await downloader.data(from: url, lane: lane)
                try data.write(to: file, options: .atomic)
                await self?.finish(key, bytes: data.count)
            } catch {
                await self?.finish(key, bytes: nil, countFailure: !Task.isCancelled)
                throw error
            }
        }
        inFlight[key] = task
        try await task.value
    }

    private func finish(_ key: Key, bytes: Int?, countFailure: Bool = true) {
        inFlight[key] = nil
        if let bytes {
            cached.insert(key)
            cachedBytes += bytes
            failures[key] = nil
        } else if countFailure {
            failures[key, default: 0] += 1
        }
    }

    private func cancelPrefetch(except key: Key) {
        for (other, task) in inFlight where other != key && !demanded.contains(other) { task.cancel() }
    }

    // MARK: - Precarga

    /// Un paso de un carril de precarga: elige el siguiente segmento y lo descarga.
    /// Elegir y reservar ocurren sin suspenderse, así que dos carriles nunca piden el mismo.
    private func prefetchStep(lane: Int) async -> Bool {
        guard !stopped, cachedBytes < Self.maxCacheBytes, lane <= allowedPrefetchLanes(), let key = nextKey() else { return false }
        do {
            try await ensure(key, lane: lane)
            return true
        } catch {
            try? await Task.sleep(for: .milliseconds(500))
            return false
        }
    }

    /// El ancho de banda del CDN es limitado: sin colchón, cada descarga de más retrasa el segmento
    /// que el reproductor necesita ya. Cuanto más margen hay por delante, más carriles se usan.
    private func allowedPrefetchLanes() -> Int {
        switch aheadSeconds(from: playbackTime) {
        case ..<30: 0
        case ..<90: 2
        default: SegmentDownloader.prefetchLanes
        }
    }

    /// Desde la posición actual hasta el final y, después, lo anterior (para poder rebobinar).
    private func nextKey() -> Key? {
        let videoCount = videoPlaylists[activeVideo].segments.count
        let audioCount = activeAudio.map { audioPlaylists[$0].segments.count } ?? 0
        let total = max(videoCount, audioCount)
        guard total > 0 else { return nil }
        for offset in 0..<total {
            let index = (playhead + offset) % total
            if index < videoCount, wanted(Key(track: .video(activeVideo), index: index)) {
                return Key(track: .video(activeVideo), index: index)
            }
            if let audio = activeAudio, index < audioCount, wanted(Key(track: .audio(audio), index: index)) {
                return Key(track: .audio(audio), index: index)
            }
        }
        return nil
    }

    private func wanted(_ key: Key) -> Bool {
        !cached.contains(key) && inFlight[key] == nil && (failures[key] ?? 0) < 2
    }
}

private extension LocalHTTPServer.Response {
    static func playlist(_ text: String) -> Self {
        .init(contentType: "application/vnd.apple.mpegurl", body: Data(text.utf8))
    }
}
