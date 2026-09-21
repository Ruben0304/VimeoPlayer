import Foundation

/// Descarga por varios "carriles": cada uno es su propia `URLSession` y, por tanto, su propia
/// conexión TCP. Así una conexión lenta o perdida solo frena a su carril (mismo enfoque que el
/// proxy de KerterApp). El carril 0 se reserva para lo que el reproductor necesita ya, y la
/// precarga usa los demás, de modo que nunca hace esperar a la reproducción.
///
/// El CDN de vimeos responde 403 a cualquier cliente sin User-Agent de navegador, incluido el
/// propio de AVFoundation: por eso AVPlayer no puede hablar con él directamente.
final class SegmentDownloader: @unchecked Sendable {
    enum Failure: Error { case http(Int), empty }

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    static let prefetchLanes = 6
    static let demandLane = 0

    private let sessions: [URLSession]

    init() {
        sessions = (0...Self.prefetchLanes).map { _ in
            let config = URLSessionConfiguration.ephemeral
            config.httpMaximumConnectionsPerHost = 1
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 120
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.urlCache = nil
            config.httpAdditionalHeaders = [
                "User-Agent": Self.userAgent,
                "Referer": "https://vimeos.net/",
                "Accept": "*/*",
            ]
            return URLSession(configuration: config)
        }
    }

    func data(from url: URL, lane: Int) async throws -> Data {
        let session = sessions[min(max(lane, 0), sessions.count - 1)]
        var lastError: Error = Failure.empty
        for attempt in 0..<5 {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(300 * (1 << (attempt - 1)))) }
            do {
                let (data, response) = try await session.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else { throw Failure.http(status) }
                guard !data.isEmpty else { throw Failure.empty }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func text(from url: URL, lane: Int = SegmentDownloader.demandLane) async throws -> String {
        let data = try await self.data(from: url, lane: lane)
        guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        return text
    }

    func invalidate() {
        sessions.forEach { $0.invalidateAndCancel() }
    }
}
