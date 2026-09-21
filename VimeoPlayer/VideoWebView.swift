import SwiftUI
import WebKit

#if os(iOS)
struct VideoWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        makeWebView()
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }
}
#elseif os(macOS)
struct VideoWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        makeWebView()
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }
}
#endif

private func makeWebView() -> WKWebView {
    let configuration = WKWebViewConfiguration()
    #if os(iOS)
    configuration.allowsInlineMediaPlayback = true
    configuration.mediaTypesRequiringUserActionForPlayback = []
    #endif

    let webView = WKWebView(frame: .zero, configuration: configuration)
    #if os(macOS)
    webView.setValue(false, forKey: "drawsBackground")
    #endif
    webView.load(URLRequest(url: URL(string: "https://vimeos.net/embed-8m5djtdb04t1.html")!))
    return webView
}
