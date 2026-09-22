import Foundation

/// Arte vertical sin texto de la app Apple TV (como el que usan HBO o Apple en
/// móvil). Sale de la API no oficial que usa tv.apple.com; es para uso personal
/// y puede dejar de funcionar si Apple la cambia, así que todo es opcional.
actor AppleTVArtwork {
    static let shared = AppleTVArtwork()

    private var cache: [String: URL?] = [:]
    private let base = "https://uts-api.itunes.apple.com/uts/v3"

    /// Parámetros de la web de Apple TV. `pfm=appletv` da el catálogo completo;
    /// con `pfm=web` solo aparece el contenido de Apple TV+.
    private struct Storefront { let sf: String; let locale: String }
    private let storefronts = [
        Storefront(sf: "143441", locale: "en-US"),
        Storefront(sf: "143454", locale: "es-ES"),
    ]

    /// Póster vertical sin título rotulado, o `nil` si Apple TV no tiene el título.
    func tallPoster(for item: CatalogItem, quality: ArtworkQuality) async -> URL? {
        let key = "\(item.kind.rawValue)|\(item.id)|\(quality.rawValue)"
        if let cached = cache[key] { return cached }

        var result: URL?
        search: for storefront in storefronts {
            for title in Set([item.originalTitle, item.displayTitle].compactMap { $0 }) {
                if let match = await match(title: title, item: item, storefront: storefront),
                   let url = await tallImage(of: match, storefront: storefront, quality: quality) {
                    result = url
                    break search
                }
            }
        }
        cache[key] = result
        return result
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

    private func match(title: String, item: CatalogItem, storefront: Storefront) async -> SearchResponse.Item? {
        guard let response: SearchResponse = await get("search", storefront: storefront, extra: ["searchTerm": title]) else { return nil }
        let wantedType = item.kind.isEpisodic ? "Show" : "Movie"
        let wantedTitle = normalized(title)
        let wantedYear = item.year.flatMap(Int.init)
        let candidates = (response.data?.canvas?.shelves ?? [])
            .flatMap { $0.items ?? [] }
            .filter { $0.type == wantedType && normalized($0.title ?? "") == wantedTitle }
        // Mismo título y tipo; si hay año, se exige que coincida (±1 por estrenos a fin de año).
        return candidates.first { candidate in
            guard let wantedYear else { return true }
            guard let year = candidate.releaseYear else { return false }
            return abs(year - wantedYear) <= 1
        }
    }

    private func tallImage(of item: SearchResponse.Item, storefront: Storefront, quality: ArtworkQuality) async -> URL? {
        let path = (item.type == "Show" ? "shows/" : "movies/") + item.id
        guard let response: ContentResponse = await get(path, storefront: storefront),
              let image = response.data?.content?.images?["contentImageTall"] else { return nil }
        let width = quality.appleTallWidth
        let ratio = (image.height ?? 3636) / (image.width ?? 1680)
        let url = image.url
            .replacingOccurrences(of: "{w}", with: String(width))
            .replacingOccurrences(of: "{h}", with: String(Int((Double(width) * ratio).rounded())))
            .replacingOccurrences(of: "{f}", with: "jpg")
        return URL(string: url)
    }

    private func get<T: Decodable>(_ path: String, storefront: Storefront, extra: [String: String] = [:]) async -> T? {
        var components = URLComponents(string: "\(base)/\(path)")!
        let params = [
            "caller": "web", "pfm": "appletv", "v": "96",
            "sf": storefront.sf, "locale": storefront.locale,
            "utscf": "OjAAAAEAAAAAAAMAEAAAACMAKwAtADgA",
            "utsk": "6e3013c6d6fae3c2::::::235656c069bb0efb",
        ].merging(extra) { $1 }
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Compara títulos sin mayúsculas, acentos ni signos ("Kenan & Kel" == "kenan and kel").
    private func normalized(_ title: String) -> String {
        title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: "and")
            .replacingOccurrences(of: #"\s*\(\d{4}\)$"#, with: "", options: .regularExpression)
            .filter { $0.isLetter || $0.isNumber }
    }
}

extension ArtworkQuality {
    /// Ancho pedido del póster alto de Apple TV (el original mide 1680 px).
    var appleTallWidth: Int {
        switch self { case .medium: 700; case .high: 1000; case .veryHigh: 1680 }
    }
}
