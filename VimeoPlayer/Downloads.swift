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

/// Categoría de filtrado de descargas: por calidad/origen, no por tipo de enlace
/// (torrents y directos se mezclan dentro de cada una).
enum DownloadCategory: String, CaseIterable, Identifiable {
    case all = "Todos"
    case fourK = "4K"
    case webDL = "WEB-DL"
    case other = "Otros"

    var id: String { rawValue }
}

extension DownloadLink {
    /// Deducida del texto de calidad/servidor: no hay un campo dedicado en la API.
    var category: DownloadCategory {
        let text = (qualityText + " " + serverText).lowercased()
        if resolution >= 2160 || text.contains("4k") { return .fourK }
        if text.contains("web-dl") || text.contains("webdl") || text.contains(" web ") || text.hasPrefix("web ") {
            return .webDL
        }
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
    @State private var category: DownloadCategory = .all

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
        LinearGradient(colors: [Color(white: 0.14), .black], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Descargar")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(target.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .padding(9)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 14)
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
            }
            .frame(maxHeight: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Segmentado nativo tipo macOS; solo muestra pestañas con enlaces reales.
    private func categoryPicker(availableIn links: [DownloadLink]) -> some View {
        let present = Set(links.map(\.category))
        let categories = DownloadCategory.allCases.filter { $0 == .all || present.contains($0) }
        return Group {
            if categories.count > 2 {
                Picker("Filtrar", selection: $category) {
                    ForEach(categories) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 22)
                .padding(.bottom, 14)
            }
        }
        .onAppear {
            if !categories.contains(category) { category = .all }
        }
    }

    private func filtered(_ links: [DownloadLink]) -> [DownloadLink] {
        category == .all ? links : links.filter { $0.category == category }
    }

    private func list(_ links: [DownloadLink]) -> some View {
        let torrents = links.filter(\.isTorrent).sorted { $0.resolution > $1.resolution }
        let direct = links.filter { !$0.isTorrent }.sorted { $0.resolution > $1.resolution }
        return Group {
            if links.isEmpty {
                message("No hay enlaces en esta categoría", systemImage: "line.3.horizontal.decrease.circle")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        section("Torrent", footer: "Se abre en tu cliente de torrents.", links: torrents)
                        section("Descarga directa", footer: "MediaFire copia el enlace directo al portapapeles; el resto se abre en el navegador.", links: direct)
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 24)
                }
            }
        }
        .id(category)
        .transition(.opacity.combined(with: .move(edge: .trailing)))
        .animation(.easeOut(duration: 0.22), value: category)
    }

    @ViewBuilder
    private func section(_ title: String, footer: String, links: [DownloadLink]) -> some View {
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                ForEach(links) { link in row(link) }
                Text(footer).font(.footnote).foregroundStyle(.secondary)
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
                Image(systemName: link.isTorrent ? "arrow.down.circle.fill" : "link.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 3) {
                    Text(link.qualityText).font(.headline)
                    Text([link.lang, link.serverText].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if link.hasSubtitles {
                    Text("SUB")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .glassEffect(.regular, in: Capsule())
                }
                if let size = link.size, !size.isEmpty {
                    Text(size).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                trailingIcon(for: link)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
            Image(systemName: link.isMediaFire ? "doc.on.doc" : "arrow.up.forward")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.secondary)
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
