import Foundation

/// Contraseña habitual de los RAR de esta fuente; editable en los ajustes de la app.
enum RARSettings {
    static let passwordKey = "rarPassword"
    static let defaultPassword = "cc"
}

enum PlaybackSettings {
    /// Por defecto VLC solo se usa cuando hace falta (MKV/RAR); esto lo activa también para el resto.
    static let preferVLCKey = "preferVLC"
}

/// Reproduce en orden el vídeo de un RAR5 alojado en MediaFire (cifrado con contraseña y
/// comprimido): descarga → descifra AES → descomprime (RAR5Decoder) → va escribiendo el MKV en
/// disco. Como el algoritmo solo decodifica hacia delante, se puede ver lo ya descomprimido pero
/// no saltar a un punto que aún no se ha alcanzado.
final class RARVideoStream: @unchecked Sendable {
    struct Progress: Equatable, Sendable {
        var decodedBytes: Int64
        /// Bytes empaquetados recibidos de MediaFire (lo que se ha bajado de la red).
        var downloadedBytes: Int64
        var totalBytes: Int64
        var isFinished: Bool
        var failure: String?
    }

    enum Failure: Error { case download(String) }

    /// Más allá de esta distancia por delante de lo decodificado, se rechaza la petición en vez de
    /// bloquear al reproductor (p. ej. cuando busca el índice del MKV al final del archivo).
    static let maxLookahead: Int64 = 96 << 20

    /// Conexiones simultáneas a MediaFire. En una línea compartida, más conexiones dan más ancho de
    /// banda (cada una recibe su parte); una sola se quedaba muy por debajo de lo contratado.
    nonisolated(unsafe) static var connections = 6

    let entry: RARVideoEntry
    var totalLength: Int64 { entry.unpackedSize }
    var fileName: String { (entry.name as NSString).lastPathComponent }

    private let password: String
    private let pageURL: URL
    private let directory: URL
    private let fileURL: URL
    private let lock = NSLock()
    private var written: Int64 = 0
    private var finished = false
    private var failureText: String?
    private var stopped = false
    private let queue = ByteQueue()
    private var download: ParallelRangeDownload?
    private var readFD: Int32 = -1

    // MARK: - Apertura

    static func open(mediaFirePage: URL, password: String) async throws -> RARVideoStream {
        let direct = try await MediaFire.directLink(from: mediaFirePage)
        let entry = try await RARArchive.findVideo(password: password) { offset, count in
            try await ParallelRangeDownload.fetch(direct, offset: offset, count: count)
        }
        guard entry.method == 0 || entry.encryption != nil || entry.method > 0 else { throw RARError.noVideo }
        return RARVideoStream(entry: entry, pageURL: mediaFirePage, directURL: direct, password: password)
    }

    private var directURL: URL

    private init(entry: RARVideoEntry, pageURL: URL, directURL: URL, password: String) {
        self.entry = entry
        self.pageURL = pageURL
        self.directURL = directURL
        self.password = password
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VimeoPlayer-rar-\(UUID().uuidString)", isDirectory: true)
        fileURL = directory.appendingPathComponent("video.mkv")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        readFD = Darwin.open(fileURL.path, O_RDONLY)
    }

    deinit { if readFD >= 0 { Darwin.close(readFD) } }

    // MARK: - Ejecución

    func start() {
        let dataEnd = entry.dataOffset + entry.packedSize
        let page = pageURL
        let download = ParallelRangeDownload(
            url: directURL, start: entry.dataOffset, end: dataEnd, workers: Self.connections,
            refresh: { try await MediaFire.directLink(from: page) },
            sink: { [queue] data in queue.push(data) },
            completion: { [weak self] error in
                self?.queue.close()
                if let error { self?.fail("Descarga: \(error.localizedDescription)") }
            })
        self.download = download
        download.start()

        let thread = Thread { [weak self] in self?.decodeLoop() }
        thread.name = "VimeoPlayer.RARDecoder"
        thread.stackSize = 8 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        download?.cancel()
        queue.close()
        try? FileManager.default.removeItem(at: directory)
    }

    var progress: Progress {
        lock.lock()
        defer { lock.unlock() }
        return Progress(decodedBytes: written, downloadedBytes: download?.receivedBytes ?? 0,
                        totalBytes: totalLength, isFinished: finished, failure: failureText)
    }

    private func fail(_ text: String) {
        lock.lock()
        if failureText == nil, !stopped { failureText = text }
        lock.unlock()
    }

    private func decodeLoop() {
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }

            var aes: AESCBCStream?
            if let encryption = entry.encryption {
                let key = try RARArchive.deriveKey(password: password, salt: encryption.salt,
                                                   iterations: 1 << encryption.kdfCount)
                aes = try AESCBCStream(key: key, iv: encryption.iv)
            }

            var carry = Data()
            let read: RAR5Decoder.Reader = { [queue] buffer, capacity in
                while carry.count < 16 {
                    guard let piece = queue.pop() else { break }
                    carry.append(piece)
                }
                guard carry.count >= 16 else { return 0 }
                let usable = min(carry.count, capacity) / 16 * 16
                let chunk = carry.prefix(usable)
                carry = Data(carry.dropFirst(usable))
                guard let aes else {
                    chunk.copyBytes(to: buffer, count: usable)
                    return usable
                }
                return chunk.withUnsafeBytes { input in
                    aes.decrypt(input, into: UnsafeMutableRawBufferPointer(start: buffer, count: usable))
                }
            }
            let write: RAR5Decoder.Writer = { [weak self] data, count in
                guard let self else { return }
                try? handle.write(contentsOf: Data(bytes: data, count: count))
                self.lock.lock()
                self.written += Int64(count)
                self.lock.unlock()
            }

            if entry.method == 0 {
                // Sin comprimir: basta con descifrar y copiar.
                var remaining = entry.unpackedSize
                let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 20)
                defer { scratch.deallocate() }
                while remaining > 0 {
                    let got = read(scratch, 1 << 20)
                    if got == 0 { break }
                    let count = Int(min(Int64(got), remaining))
                    write(scratch, count)
                    remaining -= Int64(count)
                }
            } else {
                let decoder = RAR5Decoder(windowSize: entry.windowSize, extraDist: entry.extraDist,
                                          unpackedSize: entry.unpackedSize, read: read, write: write)
                try decoder.run()
            }

            lock.lock()
            if written >= totalLength { finished = true } else if failureText == nil, !stopped {
                failureText = "El archivo terminó antes de tiempo"
            }
            lock.unlock()
        } catch {
            fail("Descompresión: \(error)")
        }
    }

    // MARK: - Lectura (la usa el servidor local)

    /// Bytes desde `offset` ya decodificados (hasta `length`), esperando si todavía no existen.
    func read(offset: Int64, length: Int) async -> Data? {
        var waitedMs = 0
        while true {
            let (have, done, failed, isStopped) = snapshot()
            if isStopped { return nil }
            if offset < have {
                let count = Int(min(Int64(length), have - offset))
                var data = Data(count: count)
                let got = data.withUnsafeMutableBytes { pread(readFD, $0.baseAddress, count, off_t(offset)) }
                return got > 0 ? data.prefix(got) : nil
            }
            if failed || done { return nil }
            // Sin marcha atrás hacia delante: un salto lejano no puede esperar a que se decodifique todo.
            if offset > have + Self.maxLookahead { return nil }
            try? await Task.sleep(for: .milliseconds(100))
            waitedMs += 100
            if waitedMs > 180_000 { return nil }
        }
    }

    private func snapshot() -> (Int64, Bool, Bool, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (written, finished, failureText != nil, stopped)
    }
}

/// `RARVideoStream` + servidor local: el reproductor abre `url` como si fuera un MKV por HTTP.
final class RARStreamServer: @unchecked Sendable {
    let stream: RARVideoStream
    private let server = LocalHTTPServer()
    private(set) var url: URL

    static func start(mediaFirePage: URL, password: String) async throws -> RARStreamServer {
        let stream = try await RARVideoStream.open(mediaFirePage: mediaFirePage, password: password)
        let result = RARStreamServer(stream: stream)
        try await result.serve()
        stream.start()
        return result
    }

    private init(stream: RARVideoStream) {
        self.stream = stream
        url = URL(string: "http://127.0.0.1")!
    }

    private func serve() async throws {
        let stream = self.stream
        let port = try await server.start { path in
            guard path == "/video.mkv" else { return nil }
            return .stream(.init(contentType: "video/x-matroska", totalLength: stream.totalLength) { offset, length in
                await stream.read(offset: offset, length: length)
            })
        }
        url = URL(string: "http://127.0.0.1:\(port)/video.mkv")!
    }

    func stop() {
        server.stop()
        stream.stop()
    }
}

// MARK: - Descarga en trozos paralelos

/// Descarga un rango de bytes en trozos pequeños por varias conexiones a la vez y los entrega **en
/// orden** (el decodificador solo avanza hacia delante). Cada trabajador tiene su propia sesión, es
/// decir, su propia conexión TCP; si un trozo falla se reintenta, y tras varios fallos se renueva el
/// enlace directo (MediaFire lo hace caducar). Los trozos ya bajados esperan en memoria, con un
/// límite de adelanto para no acumular sin fin.
final class ParallelRangeDownload: @unchecked Sendable {
    static let chunkSize = 512 << 10 // múltiplo de 16 (el cifrado va en bloques de 16)
    /// Cuántos trozos por delante del que necesita el decodificador se permiten.
    private static let lookahead = 48

    private let rangeStart: Int64
    private let end: Int64
    private let workers: Int
    private let refresh: () async throws -> URL
    private let sink: (Data) -> Void
    private let completion: (Error?) -> Void

    private let lock = NSLock()
    private var url: URL
    private var nextChunk = 0
    private var emitChunk = 0
    private var ready: [Int: Data] = [:]
    private var doneBytes: Int64 = 0
    private var cancelled = false
    private var finished = false
    private var tasks: [Task<Void, Never>] = []
    private var sessions: [URLSession] = []

    private var chunkCount: Int { Int((end - rangeStart + Int64(Self.chunkSize) - 1) / Int64(Self.chunkSize)) }

    /// Bytes ya descargados (todos los trozos completos, estén o no entregados).
    var receivedBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return doneBytes
    }

    init(url: URL, start: Int64, end: Int64, workers: Int, refresh: @escaping () async throws -> URL,
         sink: @escaping (Data) -> Void, completion: @escaping (Error?) -> Void) {
        self.url = url
        rangeStart = start
        self.end = end
        self.workers = max(1, workers)
        self.refresh = refresh
        self.sink = sink
        self.completion = completion
    }

    func start() {
        for _ in 0..<workers {
            let config = URLSessionConfiguration.ephemeral
            config.httpMaximumConnectionsPerHost = 1
            config.timeoutIntervalForRequest = 30
            config.httpAdditionalHeaders = ["User-Agent": SegmentDownloader.userAgent]
            let session = URLSession(configuration: config)
            sessions.append(session)
            tasks.append(Task { [weak self] in await self?.work(session) })
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        tasks.forEach { $0.cancel() }
        sessions.forEach { $0.invalidateAndCancel() }
    }

    /// Un trozo suelto (para leer las cabeceras del RAR).
    static func fetch(_ url: URL, offset: Int64, count: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(SegmentDownloader.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=\(offset)-\(offset + Int64(count) - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 || http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: - Trabajadores

    private enum Assignment {
        case chunk(Int)
        case wait
        case none
    }

    private func take() -> Assignment {
        lock.lock()
        defer { lock.unlock() }
        if cancelled || finished { return .none }
        if nextChunk >= chunkCount { return .none }
        if nextChunk - emitChunk >= Self.lookahead { return .wait }
        defer { nextChunk += 1 }
        return .chunk(nextChunk)
    }

    private func work(_ session: URLSession) async {
        while !Task.isCancelled {
            switch take() {
            case .none:
                return
            case .wait:
                try? await Task.sleep(for: .milliseconds(150))
            case .chunk(let index):
                do {
                    let data = try await fetchChunk(index, session: session)
                    deliver(index, data)
                } catch {
                    fail(error)
                    return
                }
            }
        }
    }

    private func fetchChunk(_ index: Int, session: URLSession) async throws -> Data {
        let lower = rangeStart + Int64(index) * Int64(Self.chunkSize)
        let upper = min(lower + Int64(Self.chunkSize), end) - 1
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<8 {
            if Task.isCancelled { throw CancellationError() }
            if attempt > 0 {
                try await Task.sleep(for: .seconds(min(attempt, 5)))
                // El enlace directo puede haber caducado: se pide uno nuevo tras un par de fallos.
                if attempt >= 2, let fresh = try? await refresh() {
                    lock.lock()
                    url = fresh
                    lock.unlock()
                }
            }
            lock.lock()
            var request = URLRequest(url: url)
            lock.unlock()
            request.setValue("bytes=\(lower)-\(upper)", forHTTPHeaderField: "Range")
            do {
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 206, Int64(data.count) == upper - lower + 1 else {
                    throw URLError(.badServerResponse)
                }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func deliver(_ index: Int, _ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        ready[index] = data
        doneBytes += Int64(data.count)
        // Entrega en orden; se hace dentro del candado para no mezclar trozos.
        while let next = ready.removeValue(forKey: emitChunk) {
            sink(next)
            emitChunk += 1
        }
        if emitChunk >= chunkCount, !finished {
            finished = true
            completion(nil)
        }
    }

    private func fail(_ error: Error) {
        lock.lock()
        let already = cancelled || finished
        if !already { finished = true }
        lock.unlock()
        guard !already, !(error is CancellationError) else { return }
        cancel()
        completion(error)
    }
}

// MARK: - Cola de bytes con espera

/// Cola entre la descarga (productor) y el hilo decodificador (consumidor, bloqueante).
final class ByteQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var chunks: [Data] = []
    private var closed = false

    func push(_ data: Data) {
        condition.lock()
        chunks.append(data)
        condition.signal()
        condition.unlock()
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    /// Siguiente trozo; espera si no hay; `nil` cuando se cerró y no queda nada.
    func pop() -> Data? {
        condition.lock()
        defer { condition.unlock() }
        while chunks.isEmpty {
            if closed { return nil }
            condition.wait()
        }
        return chunks.removeFirst()
    }
}
