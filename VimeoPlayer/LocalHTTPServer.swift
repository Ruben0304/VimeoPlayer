import Foundation
import Network

/// Servidor HTTP mínimo en loopback para servir HLS a AVPlayer (GET/HEAD, `Range`, keep-alive).
/// Adaptado del de KerterApp, con dos diferencias: escucha solo en 127.0.0.1 y el manejador es
/// asíncrono, porque un segmento puede tener que descargarse antes de poder responder.
final class LocalHTTPServer: @unchecked Sendable {
    struct Response {
        var status = 200
        var contentType: String
        var body: Data
    }

    typealias Handler = @Sendable (String) async -> Response?

    private let queue = DispatchQueue(label: "VimeoPlayer.LocalHTTPServer")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var handler: Handler?

    /// Arranca en un puerto libre y lo devuelve.
    func start(handler: @escaping Handler) async throws -> UInt16 {
        self.handler = handler
        return try await withCheckedThrowingContinuation { continuation in
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            guard let listener = try? NWListener(using: parameters) else {
                continuation.resume(throwing: URLError(.cannotCreateFile))
                return
            }
            self.listener = listener
            var reported = false
            listener.stateUpdateHandler = { state in
                guard !reported else { return }
                switch state {
                case .ready:
                    reported = true
                    if let port = listener.port?.rawValue, port != 0 {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: URLError(.cannotConnectToHost))
                    }
                case .failed(let error):
                    reported = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    reported = true
                    continuation.resume(throwing: URLError(.cancelled))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
            handler = nil
        }
    }

    // MARK: - Conexiones

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.queue.async { self?.connections[id] = nil }
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, pending: Data())
    }

    private static let headerEnd = Data("\r\n\r\n".utf8)

    /// Atiende las peticiones de una conexión de una en una: cada respuesta se envía
    /// entera antes de leer la siguiente petición.
    private func receive(on connection: NWConnection, pending: Data) {
        if let end = pending.range(of: Self.headerEnd) {
            let head = String(decoding: pending[pending.startIndex..<end.lowerBound], as: UTF8.self)
            let rest = Data(pending[end.upperBound...])
            respond(to: head, on: connection) { [weak self] in self?.receive(on: connection, pending: rest) }
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = pending
            if let data { buffer.append(data) }
            if isComplete || error != nil || buffer.count > 64 * 1024 {
                connection.cancel()
                return
            }
            self.receive(on: connection, pending: buffer)
        }
    }

    private func respond(to head: String, on connection: NWConnection, then next: @escaping () -> Void) {
        let lines = head.components(separatedBy: "\r\n")
        let request = lines.first?.split(separator: " ") ?? []
        guard request.count >= 2 else { return send(400, on: connection, then: next) }
        let method = request[0]
        guard method == "GET" || method == "HEAD" else { return send(405, on: connection, then: next) }
        let path = String(request[1].split(separator: "?").first ?? "")
        let range = Self.header("range", in: lines)
        guard let handler else { return send(404, on: connection, then: next) }

        Task {
            guard let response = await handler(path) else {
                return self.send(404, on: connection, then: next)
            }
            var status = response.status
            var body = response.body
            var extra = ""
            if status == 200, let range {
                guard let (lower, upper) = Self.byteRange(range, count: body.count) else {
                    return self.send(416, extra: "Content-Range: bytes */\(body.count)\r\n", on: connection, then: next)
                }
                extra = "Content-Range: bytes \(lower)-\(upper)/\(body.count)\r\n"
                body = body.subdata(in: lower..<(upper + 1))
                status = 206
            }
            self.send(status, contentType: response.contentType, body: body, extra: extra,
                      includeBody: method == "GET", on: connection, then: next)
        }
    }

    private func send(_ status: Int, contentType: String = "text/plain", body: Data = Data(),
                      extra: String = "", includeBody: Bool = true,
                      on connection: NWConnection, then next: @escaping () -> Void) {
        let reason = [200: "OK", 206: "Partial Content", 400: "Bad Request", 404: "Not Found",
                      405: "Method Not Allowed", 416: "Range Not Satisfiable"][status] ?? "Error"
        let header = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Accept-Ranges: bytes\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Connection: keep-alive\r\n"
            + extra + "\r\n"
        var out = Data(header.utf8)
        if includeBody { out.append(body) }
        connection.send(content: out, completion: .contentProcessed { error in
            if error != nil { connection.cancel() } else { next() }
        })
    }

    private static func header(_ name: String, in lines: [String]) -> String? {
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == name else { continue }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// `bytes=a-b`, `bytes=a-` o `bytes=-n` → rango inclusivo dentro de `count`.
    private static func byteRange(_ value: String, count: Int) -> (Int, Int)? {
        guard value.hasPrefix("bytes="), count > 0 else { return nil }
        let spec = value.dropFirst("bytes=".count).split(separator: ",").first ?? ""
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let suffix = Int(parts[1]), suffix > 0 else { return nil }
            return (max(0, count - suffix), count - 1)
        }
        guard let lower = Int(parts[0]), lower < count else { return nil }
        let upper = parts[1].isEmpty ? count - 1 : min(Int(parts[1]) ?? count - 1, count - 1)
        return upper >= lower ? (lower, upper) : nil
    }
}
