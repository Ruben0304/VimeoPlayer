import Foundation
import WebKit

/// Usa WebKit únicamente como transporte para un CDN que rechaza URLSession.
/// No se presenta en pantalla: AVPlayer sigue consumiendo el HLS local.
@MainActor
final class WebStreamFetcher: NSObject, WKNavigationDelegate {
    private let webView = WKWebView(frame: .zero)
    private let pageURL: URL
    private var navigationContinuation: CheckedContinuation<Void, Error>?

    private init(pageURL: URL) {
        self.pageURL = pageURL
        super.init()
    }

    static func make(pageURL: URL) async throws -> WebStreamFetcher {
        let fetcher = WebStreamFetcher(pageURL: pageURL)
        try await fetcher.prepare()
        return fetcher
    }

    func text(from url: URL) async throws -> String {
        let result = try await evaluateFetch(url: url, binary: false)
        guard let text = result as? String else { throw URLError(.cannotDecodeContentData) }
        return text
    }

    func data(from url: URL) async throws -> Data {
        let result = try await evaluateFetch(url: url, binary: true)
        guard let encoded = result as? String, let data = Data(base64Encoded: encoded) else {
            throw URLError(.cannotDecodeContentData)
        }
        return data
    }

    private func prepare() async throws {
        try await withCheckedThrowingContinuation { continuation in
            navigationContinuation = continuation
            webView.navigationDelegate = self
            webView.load(URLRequest(url: pageURL))
        }
    }

    private func evaluateFetch(url: URL, binary: Bool) async throws -> Any {
        let encodedURL = try JSONEncoder().encode(url.absoluteString)
        guard let jsonURL = String(data: encodedURL, encoding: .utf8) else { throw URLError(.badURL) }
        let body: String
        if binary {
            body = """
            r.arrayBuffer().then(buffer => { const bytes = new Uint8Array(buffer); let binary = ''; for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000)); return btoa(binary); })
            """
        } else {
            body = "r.text()"
        }
        let script = """
        fetch(\(jsonURL), { credentials: 'include', referrer: '\(pageURL.absoluteString)' })
          .then(r => { if (!r.ok) throw new Error('HTTP ' + r.status); return \(body); })
        """
        guard let result = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) else {
            throw URLError(.cannotDecodeContentData)
        }
        return result
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationContinuation?.resume()
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }
}
