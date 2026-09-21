import SwiftUI

struct SeasonDownloadRequest: Identifiable {
    let seriesTitle: String
    let season: Int
    let episodes: [Episode]

    var id: Int { season }
}

/// De dónde salen los enlaces de la temporada.
enum DownloadSource: Hashable {
    case mediafire, torrent, host(String)

    init(_ link: DownloadLink) {
        if link.isMediaFire { self = .mediafire }
        else if link.isTorrent { self = .torrent }
        else { self = .host(link.serverText) }
    }

    var title: String {
        switch self {
        case .mediafire: "MediaFire"
        case .torrent: "Torrent"
        case .host(let name): name
        }
    }

    var order: String {
        switch self {
        case .mediafire: "0"
        case .torrent: "1"
        case .host(let name): "2" + name
        }
    }
}

extension DownloadLink {
    /// Calidad + idioma, p. ej. "Dual 1080p · Latino - Inglés".
    var variant: String {
        [qualityText, lang].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

@MainActor
final class SeasonDownloadModel: ObservableObject {
    struct Entry {
        let episode: Episode
        let links: [DownloadLink]
    }

    struct Collected {
        var links: [String] = []
        var skipped = 0
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var loadProgress: (done: Int, total: Int)?
    @Published private(set) var copyProgress: (done: Int, total: Int)?
    @Published var source: DownloadSource?
    @Published var variant: String?

    var isLoading: Bool { loadProgress != nil }
    var isCopying: Bool { copyProgress != nil }

    var sources: [DownloadSource] {
        Set(entries.flatMap { $0.links.map(DownloadSource.init) }).sorted { $0.order < $1.order }
    }

    /// Versiones de la fuente elegida, ordenadas por cobertura y luego por resolución.
    var variants: [String] {
        guard let source else { return [] }
        var coverage: [String: Int] = [:]
        var resolution: [String: Int] = [:]
        for entry in entries {
            let mine = entry.links.filter { DownloadSource($0) == source }
            for link in mine { resolution[link.variant] = max(resolution[link.variant] ?? 0, link.resolution) }
            for variant in Set(mine.map(\.variant)) { coverage[variant, default: 0] += 1 }
        }
        return coverage.keys.sorted {
            if coverage[$0] != coverage[$1] { return coverage[$0]! > coverage[$1]! }
            return (resolution[$0] ?? 0) > (resolution[$1] ?? 0)
        }
    }

    func coverage(of variant: String) -> Int {
        entries.filter { entry in
            entry.links.contains { DownloadSource($0) == source && $0.variant == variant }
        }.count
    }

    func load(_ episodes: [Episode]) async {
        guard entries.isEmpty, !isLoading else { return }
        loadProgress = (0, episodes.count)
        let results = await Self.concurrentMap(episodes, limit: 6, onProgress: { [weak self] done in
            self?.loadProgress = (done, episodes.count)
        }) { episode in
            Entry(episode: episode, links: (try? await LaMovieAPI.downloads(postId: episode.id)) ?? [])
        }
        entries = results.sorted { $0.episode.episodeNumber < $1.episode.episodeNumber }
        loadProgress = nil
        source = sources.first
        variant = variants.first
    }

    func selectSource(_ new: DownloadSource?) {
        source = new
        variant = variants.first
    }

    /// Enlace elegido para un episodio: la versión pedida o, si no la tiene, la mejor de la misma fuente.
    private func choice(for entry: Entry) -> DownloadLink? {
        let mine = entry.links.filter { DownloadSource($0) == source }
        return mine.first { $0.variant == variant } ?? mine.max { $0.resolution < $1.resolution }
    }

    var chosenCount: Int { entries.filter { choice(for: $0) != nil }.count }
    var fallbackCount: Int {
        entries.filter { entry in
            guard let link = choice(for: entry) else { return false }
            return link.variant != variant
        }.count
    }

    /// Reúne un enlace por episodio. En MediaFire resuelve el enlace directo de cada uno.
    func collect() async -> Collected {
        let chosen = entries.compactMap { choice(for: $0) }
        var result = Collected(skipped: entries.count - chosen.count)
        copyProgress = (0, chosen.count)
        defer { copyProgress = nil }

        if source == .mediafire {
            let resolved = await Self.concurrentMap(chosen, limit: 4, onProgress: { [weak self] done in
                self?.copyProgress = (done, chosen.count)
            }) { link -> String? in
                guard let page = URL(string: link.url) else { return nil }
                return try? await MediaFire.directLink(from: page).absoluteString
            }
            for link in resolved {
                if let link { result.links.append(link) } else { result.skipped += 1 }
            }
        } else {
            result.links = chosen.map(\.url)
        }
        return result
    }

    /// Ejecuta `transform` sobre todos los elementos con un máximo de `limit` a la vez, conservando el orden.
    private static func concurrentMap<T, R>(
        _ items: [T],
        limit: Int,
        onProgress: @escaping @MainActor (Int) -> Void,
        _ transform: @escaping (T) async -> R
    ) async -> [R] {
        var results = [R?](repeating: nil, count: items.count)
        await withTaskGroup(of: (Int, R).self) { group in
            var next = 0
            var done = 0
            func addNext() {
                guard next < items.count else { return }
                let index = next
                next += 1
                group.addTask { (index, await transform(items[index])) }
            }
            for _ in 0..<min(limit, items.count) { addNext() }
            while let (index, value) = await group.next() {
                results[index] = value
                done += 1
                await onProgress(done)
                addNext()
            }
        }
        return results.compactMap { $0 }
    }
}

/// Hoja para copiar de una vez los enlaces de todos los episodios de una temporada.
struct SeasonDownloadSheet: View {
    let request: SeasonDownloadRequest

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SeasonDownloadModel()
    @State private var toast: Toast?
    @State private var copied = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.16), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                header
                content
            }
        }
        .toast($toast)
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 540)
        #endif
        .task { await model.load(request.episodes) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Descargar temporada").font(.title.bold())
                Text("\(request.seriesTitle) · Temporada \(request.season) · \(request.episodes.count) episodios")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button { dismiss() } label: { GlassIconLabel(systemImage: "xmark", size: 36) }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        if let progress = model.loadProgress {
            VStack(spacing: 14) {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .frame(maxWidth: 260)
                Text("Leyendo enlaces… \(progress.done)/\(progress.total)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.sources.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.dotted").font(.largeTitle)
                Text("No hay descargas disponibles para esta temporada").font(.headline)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            options
        }
    }

    private var options: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                card("Fuente") {
                    Picker("Fuente", selection: Binding(get: { model.source }, set: { model.selectSource($0) })) {
                        ForEach(model.sources, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                card("Versión") {
                    Picker("Versión", selection: $model.variant) {
                        ForEach(model.variants, id: \.self) { variant in
                            Text("\(variant)  (\(model.coverage(of: variant))/\(model.entries.count))")
                                .tag(Optional(variant))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                summary

                Button { Task { await copyAll() } } label: {
                    GlassButtonLabel(title: buttonTitle, systemImage: copied ? "checkmark" : "doc.on.doc",
                                     prominent: true, fullWidth: true)
                }
                .buttonStyle(.plain)
                .disabled(model.isCopying || model.chosenCount == 0)

                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: 620)
        }
    }

    private var summary: some View {
        var parts = ["\(model.chosenCount) de \(model.entries.count) episodios con enlace"]
        if model.fallbackCount > 0 { parts.append("\(model.fallbackCount) con otra versión") }
        return Text(parts.joined(separator: " · "))
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private var buttonTitle: String {
        if let progress = model.copyProgress { return "Obteniendo enlaces… \(progress.done)/\(progress.total)" }
        return copied ? "Enlaces copiados" : "Copiar \(model.chosenCount) enlaces"
    }

    private var footer: String {
        switch model.source {
        case .mediafire:
            "Se copia el enlace directo de cada episodio, uno por línea. Pégalos en Motrix (Nueva tarea) y empezarán a la vez; los enlaces caducan, así que hazlo enseguida."
        case .torrent:
            "Se copia el enlace magnet de cada episodio, uno por línea."
        default:
            "Se copia la página de descarga de cada episodio, uno por línea (no son enlaces directos)."
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func copyAll() async {
        copied = false
        let collected = await model.collect()
        guard !collected.links.isEmpty else {
            toast = Toast(text: "No se pudo obtener ningún enlace", systemImage: "exclamationmark.triangle.fill")
            return
        }
        Clipboard.copy(collected.links.joined(separator: "\n"))
        copied = true
        let text = collected.skipped == 0
            ? "\(collected.links.count) enlaces copiados"
            : "\(collected.links.count) enlaces copiados · \(collected.skipped) sin enlace"
        toast = Toast(text: text, systemImage: "checkmark.circle.fill")
    }
}
