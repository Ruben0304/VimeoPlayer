import Foundation
import Network
import WebKit

/// Reempaqueta un HLS VOD como dos playlists locales (vídeo y audio). Mientras
/// AVPlayer consume el colchón local, los restantes segmentos se descargan en
/// paralelo y se publican en las playlists conforme terminan.
final class VODProxy: @unchecked Sendable {
    struct Segment {
        let duration: Double
        let remoteURL: URL
    }

    private let lock = NSLock()
    private let directory: URL
    private let video: [Segment]
    private let audio: [Segment]
    private let fetcher: WebStreamFetcher
    private var videoReady = Set<Int>()
    private var audioReady = Set<Int>()
    private var finished = false
    private let server: LoopbackServer

    private(set) var localURL = URL(string: "http://127.0.0.1")!

    private init(video: [Segment], audio: [Segment], fetcher: WebStreamFetcher) async throws {
        self.video = video
        self.audio = audio
        self.fetcher = fetcher
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VimeoPlayer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        server = LoopbackServer()
        localURL = try await server.start { [weak self] path in self?.response(for: path) }
    }

    deinit { stop() }

    static func start(source: URL, pageURL: URL) async throws -> VODProxy {
        let fetcher = try await WebStreamFetcher.make(pageURL: pageURL)
        let master = try await fetcher.text(from: source)
        let (videoURL, audioURL) = try selectStreams(in: master, baseURL: source)
        async let videoPlaylist = fetcher.text(from: videoURL)
        async let audioPlaylist = fetcher.text(from: audioURL)
        let video = try parseMediaPlaylist(await videoPlaylist, baseURL: videoURL)
        let audio = try parseMediaPlaylist(await audioPlaylist, baseURL: audioURL)
        guard !video.isEmpty, !audio.isEmpty else { throw URLError(.cannotParseResponse) }

        let proxy = try await VODProxy(video: video, audio: audio, fetcher: fetcher)
        try await proxy.prefetchInitialBuffer()
        proxy.downloadRemainingSegments()
        return proxy
    }

    func stop() {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    private func prefetchInitialBuffer() async throws {
        // Tres segmentos de cada pista dan unos 30 s de margen antes de que
        // AVPlayer empiece a pedir al servidor local.
        let count = min(3, video.count, audio.count)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask { try await self.fetch(index, track: .video) }
                group.addTask { try await self.fetch(index, track: .audio) }
            }
            try await group.waitForAll()
        }
    }

    private func downloadRemainingSegments() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.download(track: .video) }
                group.addTask { await self.download(track: .audio) }
            }
            self.lock.withLock { self.finished = true }
        }
    }

    private enum Track { case video, audio }

    private func download(track: Track) async {
        let start = min(3, track == .video ? video.count : audio.count)
        let total = track == .video ? video.count : audio.count
        // Seis tareas independientes: evita que una conexión lenta bloquee la
        // lectura de los demás fragmentos, como los carriles de Kerter.
        await withTaskGroup(of: Void.self) { group in
            var next = start
            for _ in 0..<min(6, total - start) {
                group.addTask { await self.fetchIgnoringError(next, track: track) }
                next += 1
            }
            while await group.next() != nil {
                guard next < total else { continue }
                group.addTask { await self.fetchIgnoringError(next, track: track) }
                next += 1
            }
        }
    }

    private func fetchIgnoringError(_ index: Int, track: Track) async {
        try? await fetch(index, track: track)
    }

    private func fetch(_ index: Int, track: Track) async throws {
        let segment = track == .video ? video[index] : audio[index]
        let data = try await fetcher.data(from: segment.remoteURL)
        try data.write(to: file(index, track: track), options: .atomic)
        _ = lock.withLock {
            if track == .video { videoReady.insert(index) } else { audioReady.insert(index) }
        }
    }

    private func file(_ index: Int, track: Track) -> URL {
        directory.appendingPathComponent(track == .video ? "v-\(index).ts" : "a-\(index).ts")
    }

    private func response(for path: String) -> LoopbackServer.Response? {
        lock.withLock {
            switch path {
            case "/master.m3u8":
                return .playlist(masterPlaylist())
            case "/video.m3u8":
                return .playlist(mediaPlaylist(track: .video))
            case "/audio.m3u8":
                return .playlist(mediaPlaylist(track: .audio))
            default:
                guard let (track, index) = localSegment(for: path),
                      (track == .video ? videoReady : audioReady).contains(index),
                      let data = try? Data(contentsOf: file(index, track: track)) else { return nil }
                return .init(contentType: "video/mp2t", body: data)
            }
        }
    }

    private func masterPlaylist() -> String {
        """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Audio",DEFAULT=YES,AUTOSELECT=YES,URI="/audio.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=2360736,RESOLUTION=1728x720,AUDIO="audio"
        /video.m3u8
        """
    }

    private func mediaPlaylist(track: Track) -> String {
        let segments = track == .video ? video : audio
        let ready = track == .video ? videoReady : audioReady
        let contiguous = segments.indices.prefix { ready.contains($0) }.count
        let target = Int((segments.map(\.duration).max() ?? 10).rounded(.up))
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:EVENT"]
        for index in 0..<contiguous {
            lines.append("#EXTINF:\(String(format: "%.3f", segments[index].duration)),")
            lines.append(track == .video ? "/v/\(index).ts" : "/a/\(index).ts")
        }
        if finished && contiguous == segments.count { lines.append("#EXT-X-ENDLIST") }
        return lines.joined(separator: "\n") + "\n"
    }

    private func localSegment(for path: String) -> (Track, Int)? {
        let parts = path.split(separator: "/")
        guard parts.count == 2, let index = Int(parts[1].dropLast(3)) else { return nil }
        return parts[0] == "v" ? (.video, index) : parts[0] == "a" ? (.audio, index) : nil
    }


    private static func selectStreams(in master: String, baseURL: URL) throws -> (URL, URL) {
        let lines = master.split(whereSeparator: \.isNewline).map(String.init)
        var audio: URL?
        var videos: [(bandwidth: Int, url: URL)] = []
        for index in lines.indices {
            let line = lines[index]
            if line.hasPrefix("#EXT-X-MEDIA:"), line.contains("TYPE=AUDIO"),
               (line.contains("DEFAULT=YES") || audio == nil), let value = attribute("URI", in: line), let url = URL(string: value, relativeTo: baseURL)?.absoluteURL {
                audio = url
            }
            if line.hasPrefix("#EXT-X-STREAM-INF:"), index + 1 < lines.endIndex,
               let url = URL(string: lines[index + 1], relativeTo: baseURL)?.absoluteURL {
                videos.append((Int(attribute("BANDWIDTH", in: line) ?? "0") ?? 0, url))
            }
        }
        guard let audio, let video = videos.max(by: { $0.bandwidth < $1.bandwidth })?.url else {
            throw URLError(.cannotParseResponse)
        }
        return (video, audio)
    }

    private static func parseMediaPlaylist(_ text: String, baseURL: URL) throws -> [Segment] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        var duration: Double?
        var result: [Segment] = []
        for line in lines {
            if line.hasPrefix("#EXTINF:") {
                duration = Double(line.dropFirst(8).split(separator: ",").first ?? "")
            } else if !line.hasPrefix("#"), let duration,
                      let url = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                result.append(Segment(duration: duration, remoteURL: url))
            }
        }
        return result
    }

    private static func attribute(_ key: String, in line: String) -> String? {
        let pattern = "(?:^|,)\(key)=\\\"?([^,\\\"]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }
}

private final class LoopbackServer: @unchecked Sendable {
    struct Response { let contentType: String; let body: Data
        static func playlist(_ text: String) -> Response { .init(contentType: "application/vnd.apple.mpegurl", body: Data(text.utf8)) }
    }

    private let queue = DispatchQueue(label: "VimeoPlayer.LoopbackServer")
    private var listener: NWListener?
    private var handler: ((String) -> Response?)?

    func start(handler: @escaping (String) -> Response?) async throws -> URL {
        self.handler = handler
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            guard let listener = try? NWListener(using: parameters) else {
                continuation.resume(throwing: URLError(.cannotCreateFile)); return
            }
            self.listener = listener
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] in self?.accept($0) }
            listener.start(queue: self.queue)
        }
        guard port != 0, let url = URL(string: "http://127.0.0.1:\(port)/master.m3u8") else { throw URLError(.cannotConnectToHost) }
        return url
    }

    func stop() { listener?.cancel(); listener = nil }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, pending: Data())
    }

    private func receive(on connection: NWConnection, pending: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = pending
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil || buffer.count > 32_768 { connection.cancel() }
                else { self.receive(on: connection, pending: buffer) }
                return
            }
            defer { connection.cancel() }
            guard let request = String(data: buffer[..<end.lowerBound], encoding: .utf8),
                  let first = request.components(separatedBy: "\r\n").first else { return }
            let pieces = first.split(separator: " ")
            guard pieces.count > 1 else { return }
            let path = String(pieces[1].split(separator: "?").first ?? "")
            guard let response = self.handler?(path) else {
                let notFound = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: notFound, completion: .contentProcessed { _ in })
                return
            }
            let header = "HTTP/1.1 200 OK\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
            var output = Data(header.utf8); output.append(response.body)
            connection.send(content: output, completion: .contentProcessed { _ in })
        }
    }
}
