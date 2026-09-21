import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Clipboard {
    static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }
}

/// Categoría de descarga por calidad (no por tipo de enlace: torrents y directos se
/// mezclan dentro de cada una). "Hi" son solo los 1080p WEB-DL.
enum DownloadCategory: String, CaseIterable, Identifiable {
    case fourK = "4K"
    case fullHDHi = "Full HD (Hi)"
    case fullHDLow = "Full HD (Low)"
    case hd720 = "720p"
    case other = "Otros"

    var id: String { rawValue }
}

extension DownloadLink {
    /// WEB-DL deducido del texto de calidad/servidor: no hay un campo dedicado en la API.
    var isWebDL: Bool {
        let text = (qualityText + " " + serverText).lowercased()
        return text.contains("web-dl") || text.contains("webdl") || text.contains(" web ") || text.hasPrefix("web ")
    }

    var category: DownloadCategory {
        let text = (qualityText + " " + serverText).lowercased()
        if resolution >= 2160 || text.contains("4k") { return .fourK }
        if resolution >= 1080 { return isWebDL ? .fullHDHi : .fullHDLow }
        if resolution >= 720 { return .hd720 }
        return .other
    }
}

/// Hoja con todas las opciones de descarga de una película o episodio.
struct DownloadSheet: View {
    let target: PlaybackTarget

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var links: [DownloadLink]?
    @State private var failed = false
    @State private var resolvingID: String?
    @State private var copiedID: String?
    @State private var toast: Toast?
    @State private var selectedCategory: DownloadCategory?
    @Namespace private var tabUnderline

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                header
                content
            }
        }
        .toast($toast)
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
        .task { await load() }
    }

    private var background: some View {
        ZStack {
            Color.black
            RadialGradient(colors: [Color(white: 0.16), .clear], center: .top, startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("DESCARGAR")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(3)
                    .foregroundStyle(.white.opacity(0.5))
                Text(target.title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(10)
                    .background(.white.opacity(0.1), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var content: some View {
        if let links {
            if links.isEmpty {
                message("No hay descargas disponibles", systemImage: "arrow.down.circle.dotted")
            } else {
                VStack(spacing: 0) {
                    categoryPicker(availableIn: links)
                    list(filtered(links))
                }
            }
        } else if failed {
            VStack(spacing: 12) {
                message("No se pudieron cargar las descargas", systemImage: "wifi.exclamationmark")
                Button { Task { await load() } } label: {
                    Label("Reintentar", systemImage: "arrow.clockwise")
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Capsule())
                .pointerCursor()
            }
            .frame(maxHeight: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func categories(in links: [DownloadLink]) -> [DownloadCategory] {
        let present = Set(links.map(\.category))
        return DownloadCategory.allCases.filter { present.contains($0) }
    }

    /// Categoría activa: la elegida si existe, si no la de mayor calidad disponible.
    private func category(in links: [DownloadLink]) -> DownloadCategory? {
        let available = categories(in: links)
        if let selectedCategory, available.contains(selectedCategory) { return selectedCategory }
        return available.first
    }

    /// Pestañas de calidad con subrayado, estilo HBO; solo las que tienen enlaces reales.
    private func categoryPicker(availableIn links: [DownloadLink]) -> some View {
        let available = categories(in: links)
        let current = category(in: links)
        return VStack(spacing: 0) {
            if available.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 26) {
                        ForEach(available) { tab in
                            Button {
                                withAnimation(.easeInOut(duration: 0.22)) { selectedCategory = tab }
                            } label: {
                                VStack(spacing: 9) {
                                    Text(tab.rawValue.uppercased())
                                        .font(.system(size: 13, weight: .semibold))
                                        .tracking(1.4)
                                        .lineLimit(1)
                                        .fixedSize()
                                        .foregroundStyle(tab == current ? .white : .white.opacity(0.45))
                                    ZStack {
                                        Capsule().fill(.clear).frame(height: 2)
                                        if tab == current {
                                            Capsule().fill(.white).frame(height: 2)
                                                .matchedGeometryEffect(id: "underline", in: tabUnderline)
                                        }
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 28)
                }
                Divider().overlay(.white.opacity(0.1)).padding(.top, -1)
            }
        }
        .padding(.bottom, 8)
    }

    private func filtered(_ links: [DownloadLink]) -> [DownloadLink] {
        guard let current = category(in: links) else { return links }
        return links.filter { $0.category == current }
    }

    private func list(_ links: [DownloadLink]) -> some View {
        let torrents = links.filter(\.isTorrent).sorted { $0.resolution > $1.resolution }
        let direct = links.filter { !$0.isTorrent }.sorted { $0.resolution > $1.resolution }
        return Group {
            if links.isEmpty {
                message("No hay enlaces en esta categoría", systemImage: "line.3.horizontal.decrease.circle")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        section("Torrent", footer: "Se abre en tu cliente de torrents.", links: torrents)
                        section("Descarga directa", footer: "MediaFire copia el enlace directo al portapapeles; el resto se abre en el navegador.", links: direct)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 16)
                    .padding(.bottom, 28)
                }
            }
        }
        .id(links.first?.category)
        .transition(.opacity.combined(with: .move(edge: .trailing)))
        .animation(.easeOut(duration: 0.22), value: links.first?.category)
    }

    @ViewBuilder
    private func section(_ title: String, footer: String, links: [DownloadLink]) -> some View {
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(2.4)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.bottom, 10)
                ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
                    if index > 0 { Divider().overlay(.white.opacity(0.08)) }
                    row(link)
                }
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 12)
            }
        }
    }

    private func row(_ link: DownloadLink) -> some View {
        HStack(spacing: 8) {
            rowButton(link)
            #if os(macOS)
            // MediaFire: además de copiar el enlace, se puede reproducir el RAR (1080p) desde aquí.
            if link.isMediaFire, let page = URL(string: link.url) {
                PlayButton(target: PlaybackTarget(postId: target.postId, title: "\(target.title) · \(link.qualityText)", mediaFire: page)) {
                    GlassIconLabel(systemImage: "play.fill", size: 48)
                }
                .buttonStyle(.plain)
                .help("Reproducir desde MediaFire")
            }
            #endif
        }
    }

    private func rowButton(_ link: DownloadLink) -> some View {
        Button {
            Task { await activate(link) }
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(link.qualityText)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text([link.lang, link.serverText].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if link.hasSubtitles {
                    Text("SUB")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.4), lineWidth: 1))
                }
                if let size = link.size, !size.isEmpty {
                    Text(size)
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }
                trailingIcon(for: link)
                    .frame(width: 20)
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copiar enlace", systemImage: "doc.on.doc") { Clipboard.copy(link.url) }
        }
    }

    @ViewBuilder
    private func trailingIcon(for link: DownloadLink) -> some View {
        if resolvingID == link.id {
            ProgressView().controlSize(.small)
        } else if copiedID == link.id {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Image(systemName: link.isMediaFire ? "doc.on.doc" : "arrow.down.to.line")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private func message(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.largeTitle)
            Text(text).font(.headline)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        failed = false
        do {
            links = try await LaMovieAPI.downloads(postId: target.postId)
        } catch {
            failed = true
        }
    }

    /// MediaFire: resuelve y copia el enlace directo. Los demás enlaces se abren en el sistema.
    private func activate(_ link: DownloadLink) async {
        guard let url = URL(string: link.url) else { return }
        guard link.isMediaFire else {
            openURL(url)
            return
        }
        guard resolvingID == nil else { return }
        resolvingID = link.id
        defer { resolvingID = nil }
        do {
            let direct = try await MediaFire.directLink(from: url)
            Clipboard.copy(direct.absoluteString)
            copiedID = link.id
            toast = Toast(text: "Enlace directo copiado", systemImage: "checkmark.circle.fill")
            try? await Task.sleep(for: .seconds(2.5))
            if copiedID == link.id { copiedID = nil }
        } catch {
            toast = Toast(text: "No se pudo obtener el enlace directo", systemImage: "exclamationmark.triangle.fill")
            openURL(url)
        }
    }
}

extension DownloadLink {
    var isMediaFire: Bool {
        guard let host = URL(string: url)?.host else { return false }
        return host == "mediafire.com" || host.hasSuffix(".mediafire.com")
    }
}

/// MediaFire sirve la URL de descarga real en el botón "Download" de la página del archivo.
enum MediaFire {
    struct ResolveError: Error {}

    static func directLink(from pageURL: URL) async throws -> URL {
        var request = URLRequest(url: pageURL)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              let link = directLink(inHTML: html) else { throw ResolveError() }
        return link
    }

    static func directLink(inHTML html: String) -> URL? {
        // El <a id="downloadButton"> lleva el enlace en `href`, o en base64 en `data-scrambled-url`.
        if let tag = firstMatch(#"<a\b[^>]*\bid="downloadButton"[^>]*>"#, in: html) {
            if let href = firstMatch(#"href="([^"]+)""#, in: tag, group: 1), href.hasPrefix("http") {
                return URL(string: href.decodingHTMLEntities)
            }
            if let scrambled = firstMatch(#"data-scrambled-url="([^"]+)""#, in: tag, group: 1),
               let data = Data(base64Encoded: scrambled),
               let decoded = String(data: data, encoding: .utf8), decoded.hasPrefix("http") {
                return URL(string: decoded)
            }
        }
        // Respaldo: cualquier enlace al CDN de descargas de MediaFire.
        return firstMatch(#"https?://download[0-9]*\.mediafire\.com/[^"'\s<>]+"#, in: html)
            .flatMap { URL(string: $0.decodingHTMLEntities) }
    }

    private static func firstMatch(_ pattern: String, in text: String, group: Int = 0) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }
}
