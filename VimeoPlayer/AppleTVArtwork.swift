import Foundation

/// Arte vertical sin texto de la app Apple TV (como el que usan HBO o Apple en
/// móvil). Sale de la API no oficial que usa tv.apple.com; es para uso personal
/// y puede dejar de funcionar si Apple la cambia, así que todo es opcional.
actor AppleTVArtwork {
    static let shared = AppleTVArtwork()

    /// Plantilla de la imagen alta (`{w}`/`{h}`/`{f}`) y su tamaño original.
    /// No depende de la calidad elegida: cambiarla no repite la búsqueda.
    private struct TallTemplate { let url: String; let width: Double; let height: Double }

    /// Resultados definitivos (encontrado o no existe). Los fallos de red no se guardan.
    private var cache: [String: TallTemplate?] = [:]
    /// Búsquedas en curso, para que el hero y la ficha no pidan lo mismo a la vez.
    private var inFlight: [String: Task<FetchOutcome<TallTemplate>, Never>] = [:]

    private let base = "https://uts-api.itunes.apple.com/uts/v3"

    /// Parámetros de la web de Apple TV. `pfm=appletv` da el catálogo completo;
    /// con `pfm=web` solo aparece el contenido de Apple TV+.
    private struct Storefront { let sf: String; let locale: String }
    private let storefronts = [
        Storefront(sf: "143441", locale: "en-US"),
        Storefront(sf: "143454", locale: "es-ES"),
    ]

    /// Póster vertical sin título rotulado, o `nil` si Apple TV no tiene el título
    /// (o no se pudo consultar; en ese caso se reintenta en la próxima llamada).
    func tallPoster(for item: CatalogItem, quality: ArtworkQuality) async -> URL? {
        let key = "\(item.kind.rawValue)|\(item.id)"
        let template: TallTemplate?
        if let cached = cache[key] {
            template = cached
        } else {
            let task = inFlight[key] ?? Task { await self.lookup(item) }
            inFlight[key] = task
            let outcome = await task.value
            inFlight[key] = nil
            switch outcome {
            case .found(let found):
                cache[key] = .some(found)
                template = found
            case .notFound:
                cache[key] = .some(nil)
                template = nil
            case .failed:
                template = nil
            }
        }
        return template.flatMap { url(from: $0, quality: quality) }
    }

    // MARK: - Búsqueda

    /// Primero con los títulos de LaMovie; si no aparece, con el título en inglés de TMDB,
    /// que es como Apple TV cataloga mucho contenido extranjero.
    private func lookup(_ item: CatalogItem) async -> FetchOutcome<TallTemplate> {
        let titles = titles(for: item)
        let first = await lookup(item, titles: titles)
        guard case .notFound = first,
              let english = await TMDBService.shared.englishTitle(for: item),
              !titles.contains(where: { normalized($0) == normalized(english) }) else { return first }
        return await lookup(item, titles: [english])
    }

    /// Los dos storefronts se consultan en paralelo; gana el de EE. UU. si ambos lo tienen.
    private func lookup(_ item: CatalogItem, titles: [String]) async -> FetchOutcome<TallTemplate> {
        async let us = lookup(item, titles: titles, storefront: storefronts[0])
        async let es = lookup(item, titles: titles, storefront: storefronts[1])
        let outcomes = await [us, es]
        if let found = outcomes.lazy.compactMap(\.value).first { return .found(found) }
        return outcomes.contains { if case .failed = $0 { true } else { false } } ? .failed : .notFound
    }

    private func lookup(_ item: CatalogItem, titles: [String], storefront: Storefront) async -> FetchOutcome<TallTemplate> {
        var failed = false
        for title in titles {
            switch await match(title: title, item: item, storefront: storefront) {
            case .failed: failed = true
            case .notFound: continue
            case .found(let match):
                switch await tallTemplate(of: match, storefront: storefront) {
                case .found(let template): return .found(template)
                case .failed: failed = true
                case .notFound: continue
                }
            }
        }
        return failed ? .failed : .notFound
    }

    /// Título original primero y luego el mostrado, sin repetir.
    private func titles(for item: CatalogItem) -> [String] {
        var seen = Set<String>()
        return [item.originalTitle, item.displayTitle]
            .compactMap { $0 }
            .filter { !$0.isEmpty && seen.insert(normalized($0)).inserted }
    }

    // MARK: - API

    private struct SearchResponse: Decodable {
        struct DataBody: Decodable { let canvas: Canvas? }
        struct Canvas: Decodable { let shelves: [Shelf]? }
        struct Shelf: Decodable { let items: [Item]? }
        struct Item: Decodable {
            let id: String
            let type: String?
            let title: String?
            let releaseDate: Double?

            var releaseYear: Int? {
                guard let releaseDate else { return nil }
                return Calendar(identifier: .gregorian).component(.year, from: Date(timeIntervalSince1970: releaseDate / 1000))
            }
        }
        let data: DataBody?
    }

    private struct ContentResponse: Decodable {
        struct DataBody: Decodable { let content: Content? }
        struct Content: Decodable { let images: [String: Image]? }
        struct Image: Decodable { let url: String; let width: Double?; let height: Double? }
        let data: DataBody?
    }

    private func match(title: String, item: CatalogItem, storefront: Storefront) async -> FetchOutcome<SearchResponse.Item> {
        let response: SearchResponse
        switch await get("search", storefront: storefront, extra: ["searchTerm": title], as: SearchResponse.self) {
        case .found(let decoded): response = decoded
        case .notFound: return .notFound
        case .failed: return .failed
        }
        let wantedType = item.kind.isEpisodic ? "Show" : "Movie"
        let wantedTitle = normalized(title)
        let candidates = (response.data?.canvas?.shelves ?? [])
            .flatMap { $0.items ?? [] }
            .filter { $0.type == wantedType && normalized($0.title ?? "") == wantedTitle }

        guard let wantedYear = item.year.flatMap(Int.init) else {
            return candidates.first.map { .found($0) } ?? .notFound
        }
        // Mismo título y tipo; de los que tienen año, el más cercano. Se admiten ±2 años:
        // el estreno de festival o de otro país a menudo difiere del de EE. UU.
        let closest = candidates
            .compactMap { candidate in candidate.releaseYear.map { (candidate, abs($0 - wantedYear)) } }
            .min { $0.1 < $1.1 }
        if let closest, closest.1 <= 2 { return .found(closest.0) }
        // Sin fecha solo se acepta si no hay ningún otro candidato con el que confundirlo.
        if candidates.count == 1, candidates[0].releaseYear == nil { return .found(candidates[0]) }
        return .notFound
    }

    private func tallTemplate(of item: SearchResponse.Item, storefront: Storefront) async -> FetchOutcome<TallTemplate> {
        let path = (item.type == "Show" ? "shows/" : "movies/") + item.id
        switch await get(path, storefront: storefront, as: ContentResponse.self) {
        case .found(let response):
            guard let image = response.data?.content?.images?["contentImageTall"] else { return .notFound }
            return .found(TallTemplate(url: image.url, width: image.width ?? 1680, height: image.height ?? 3636))
        case .notFound: return .notFound
        case .failed: return .failed
        }
    }

    private func url(from template: TallTemplate, quality: ArtworkQuality) -> URL? {
        let width = min(quality.appleTallWidth, Int(template.width))
        let height = Int((Double(width) * template.height / template.width).rounded())
        return URL(string: template.url
            .replacingOccurrences(of: "{w}", with: String(width))
            .replacingOccurrences(of: "{h}", with: String(height))
            .replacingOccurrences(of: "{f}", with: "jpg"))
    }

    private func get<T: Decodable>(_ path: String, storefront: Storefront, extra: [String: String] = [:], as type: T.Type) async -> FetchOutcome<T> {
        var components = URLComponents(string: "\(base)/\(path)")!
        let params = [
            "caller": "web", "pfm": "appletv", "v": "96",
            "sf": storefront.sf, "locale": storefront.locale,
            "utscf": "OjAAAAEAAAAAAAMAEAAAACMAKwAtADgA",
            "utsk": "6e3013c6d6fae3c2::::::235656c069bb0efb",
        ].merging(extra) { $1 }
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { return .notFound }
        // Tiempo corto: la ficha espera a este póster antes de mostrarse.
        return await URLSession.shared.fetchJSON(type, from: url, timeout: 6)
    }

    /// Compara títulos sin mayúsculas, acentos, signos ni conjunciones
    /// ("Kenan & Kel" == "kenan and kel", "Tom y Jerry" == "Tom & Jerry").
    private func normalized(_ title: String) -> String {
        title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: #"\s*\(\d{4}\)$"#, with: "", options: .regularExpression)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0 != "and" && $0 != "y" }
            .joined()
    }
}

extension ArtworkQuality {
    /// Ancho pedido del póster alto de Apple TV (el original mide 1680 px).
    var appleTallWidth: Int {
        switch self { case .medium: 700; case .high: 1000; case .veryHigh: 1680 }
    }
}
