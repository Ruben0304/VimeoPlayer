import Foundation

enum ContentKind: String {
    case movies, tvshows, animes

    var label: String {
        switch self {
        case .movies: "Película"
        case .tvshows: "Serie"
        case .animes: "Anime"
        }
    }
}

struct CatalogImages: Decodable, Hashable {
    let poster: String?
    let backdrop: String?

    var posterURL: URL? { LaMovieAPI.imageURL(poster) }
    var backdropURL: URL? { LaMovieAPI.imageURL(backdrop) }
}

struct CatalogItem: Decodable, Identifiable, Hashable {
    let id: Int
    let title: String
    let overview: String
    let slug: String
    let images: CatalogImages
    let rating: String?
    let genres: [Int]
    let type: String
    let releaseDate: String?
    let runtime: String?
    let tagline: String?
    let certification: String?

    enum CodingKeys: String, CodingKey {
        case id = "_id", title, overview, slug, images, rating, genres, type
        case releaseDate = "release_date", runtime, tagline, certification
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        slug = try c.decode(String.self, forKey: .slug)
        type = (try? c.decode(String.self, forKey: .type)) ?? ""
        overview = (try? c.decode(String.self, forKey: .overview)) ?? ""
        images = (try? c.decode(CatalogImages.self, forKey: .images)) ?? CatalogImages(poster: nil, backdrop: nil)
        genres = (try? c.decode([Int].self, forKey: .genres)) ?? []
        rating = Self.lenientString(c, .rating)
        runtime = Self.lenientString(c, .runtime)
        releaseDate = try? c.decodeIfPresent(String.self, forKey: .releaseDate)
        tagline = try? c.decodeIfPresent(String.self, forKey: .tagline)
        certification = try? c.decodeIfPresent(String.self, forKey: .certification)
    }

    // The API is inconsistent about sending numbers as strings or as numbers.
    private static func lenientString(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let string = try? c.decodeIfPresent(String.self, forKey: key) { return string }
        if let number = try? c.decodeIfPresent(Double.self, forKey: key) { return String(number) }
        return nil
    }

    var kind: ContentKind { ContentKind(rawValue: type) ?? .movies }

    /// Los títulos vienen como "Nombre (2024)"; el año ya se muestra aparte.
    var displayTitle: String {
        title.decodingHTMLEntities
            .replacingOccurrences(of: #"\s*\(\d{4}\)\s*$"#, with: "", options: .regularExpression)
    }

    var year: String? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return String(releaseDate.prefix(4))
    }

    var ratingText: String? {
        guard let rating, let value = Double(rating), value > 0 else { return nil }
        return String(format: "%.1f", value)
    }

    var runtimeText: String? {
        guard let runtime, let value = Double(runtime), value > 0 else { return nil }
        let minutes = Int(value)
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    var genreNames: [String] { genres.compactMap { Genre.names[$0] } }

    /// Línea de metadatos: año · duración · clasificación.
    var metaLine: String {
        [year, runtimeText, certification].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func == (lhs: CatalogItem, rhs: CatalogItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Los géneros llegan como IDs; la web los define en su HTML (`siteConfig`).
enum Genre {
    static let names: [Int: String] = [
        17: "Drama", 18: "Comedia", 33: "Suspense", 32: "Acción", 520: "Animación",
        96: "Terror", 180: "Crimen", 130: "Aventura", 398: "Familia", 115: "Romance",
        97: "Misterio", 131: "Ciencia ficción", 229: "Fantasía", 704: "Sci-Fi & Fantasy",
        705: "Action & Adventure", 164: "Documental", 165: "Historia", 8: "Música",
        3056: "Bélica", 6787: "Película de TV", 674: "Western", 703: "Kids",
        786: "War & Politics", 12485: "Reality", 19824: "Soap",
    ]
}

enum APIError: Error {
    case empty
}

extension String {
    /// Decodifica entidades HTML como `&amp;` o `&#8217;` (los títulos de la API las traen).
    var decodingHTMLEntities: String {
        guard contains("&") else { return self }
        var result = self
        let named = ["&amp;": "&", "&quot;": "\"", "&lt;": "<", "&gt;": ">", "&apos;": "'", "&nbsp;": " "]
        for (entity, char) in named { result = result.replacingOccurrences(of: entity, with: char) }
        let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
        let matches = regex?.matches(in: result, range: NSRange(result.startIndex..., in: result)) ?? []
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: result),
                  let hexFlag = Range(match.range(at: 1), in: result),
                  let digits = Range(match.range(at: 2), in: result),
                  let code = UInt32(result[digits], radix: result[hexFlag].isEmpty ? 10 : 16),
                  let scalar = Unicode.Scalar(code) else { continue }
            result.replaceSubrange(whole, with: String(Character(scalar)))
        }
        return result
    }
}

enum LaMovieAPI {
    private static let apiURL = URL(string: "https://lamovie.org/wp-api/v1")!
    private static let imageBase = "https://lamovie.org/wp-content/uploads"

    static func imageURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: imageBase + path)
    }

    private struct Envelope<Payload: Decodable>: Decodable {
        let error: Bool?
        let message: String?
        let data: Payload?
    }

    private struct ListingPayload: Decodable {
        let posts: [CatalogItem]

        enum CodingKeys: String, CodingKey { case posts }

        // Cuando no hay resultados `posts` llega como `{}` en lugar de `[]`.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            posts = (try? c.decode([CatalogItem].self, forKey: .posts)) ?? []
        }
    }

    private struct PlayerPayload: Decodable {
        let embeds: [Embed]
        let downloads: [DownloadLink]

        enum CodingKeys: String, CodingKey { case embeds, downloads }

        // Cada lista se decodifica aparte: si una falla, la otra sigue sirviendo.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            embeds = (try? c.decode([Embed].self, forKey: .embeds)) ?? []
            downloads = (try? c.decode([DownloadLink].self, forKey: .downloads)) ?? []
        }
    }

    private struct EpisodesPayload: Decodable {
        let posts: [Episode]
        let seasons: [String]
    }

    private static func get<Payload: Decodable>(_ path: String, _ query: [String: String], as type: Payload.Type) async throws -> Payload {
        var components = URLComponents(url: apiURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        // URLQueryItem no escapa "&", "+" ni "=" dentro del valor; hay que hacerlo a mano.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        components.percentEncodedQueryItems = query.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value.addingPercentEncoding(withAllowedCharacters: allowed))
        }
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(Envelope<Payload>.self, from: data)
        if decoded.error == true, decoded.message == "empty" { throw APIError.empty }
        guard decoded.error != true, let payload = decoded.data else { throw URLError(.cannotParseResponse) }
        return payload
    }

    static func listing(_ kind: ContentKind, orderBy: String = "latest", perPage: Int = 21) async throws -> [CatalogItem] {
        try await get("listing/" + kind.rawValue, [
            "page": "1",
            "orderBy": orderBy,
            "order": "desc",
            "postType": kind.rawValue,
            "postsPerPage": String(perPage),
        ], as: ListingPayload.self).posts
    }

    /// Búsqueda por texto (la API exige entre 3 y 16 caracteres). Sin coincidencias devuelve `[]`.
    static func search(_ text: String, perPage: Int = 30) async throws -> [CatalogItem] {
        do {
            let posts = try await get("search", [
                // La API busca sobre el título tal como está guardado, con "&" escapado como entidad.
                "q": String(text.prefix(16)).replacingOccurrences(of: "&", with: "&amp;"),
                "postType": "any",
                "postsPerPage": String(perPage),
            ], as: ListingPayload.self).posts
            // Solo mostramos lo que la app sabe abrir (no episodios sueltos, etc.).
            return posts.filter { ContentKind(rawValue: $0.type) != nil }
        } catch APIError.empty {
            return []
        }
    }

    private static func player(postId: Int) async throws -> PlayerPayload {
        try await get("player", ["postId": String(postId), "demo": "0"], as: PlayerPayload.self)
    }

    /// Fuentes de reproducción de una película o episodio.
    static func embeds(postId: Int) async throws -> [Embed] {
        try await player(postId: postId).embeds
    }

    /// Enlaces de descarga (torrents y servidores externos) de una película o episodio.
    static func downloads(postId: Int) async throws -> [DownloadLink] {
        try await player(postId: postId).downloads
    }

    /// Episodios de una temporada, y las temporadas disponibles (ascendentes).
    static func episodes(seriesId: Int, season: Int?) async throws -> (episodes: [Episode], seasons: [Int]) {
        var query = ["_id": String(seriesId), "page": "1", "postsPerPage": "100"]
        if let season { query["season"] = String(season) }
        let payload = try await get("single/episodes/list", query, as: EpisodesPayload.self)
        return (payload.posts.sorted { $0.episodeNumber < $1.episodeNumber },
                payload.seasons.compactMap(Int.init).sorted())
    }
}

struct DownloadLink: Decodable, Identifiable, Hashable {
    let url: String
    let server: String?
    let lang: String?
    let quality: String?
    let size: String?
    let subtitle: Int?

    var id: String { url }

    enum CodingKeys: String, CodingKey { case url, server, lang, quality, size, subtitle }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        server = (try? c.decodeIfPresent(String.self, forKey: .server)) ?? nil
        lang = (try? c.decodeIfPresent(String.self, forKey: .lang)) ?? nil
        quality = (try? c.decodeIfPresent(String.self, forKey: .quality)) ?? nil
        size = (try? c.decodeIfPresent(String.self, forKey: .size)) ?? nil
        subtitle = (try? c.decodeIfPresent(Int.self, forKey: .subtitle)) ?? nil
    }

    var isTorrent: Bool { url.hasPrefix("magnet:") }
    var hasSubtitles: Bool { subtitle == 1 }
    var qualityText: String { (quality?.isEmpty == false ? quality : nil) ?? "Original" }

    var serverText: String {
        if isTorrent { return "Torrent" }
        return (server?.isEmpty == false ? server : nil) ?? URL(string: url)?.host ?? "Enlace"
    }

    /// Altura en píxeles deducida de la calidad ("Dual 1080p" → 1080), para ordenar de mayor a menor.
    var resolution: Int {
        let text = qualityText.lowercased()
        if text.contains("4k") { return 2160 }
        if let range = text.range(of: #"\d{3,4}(?=p)"#, options: .regularExpression) { return Int(text[range]) ?? 0 }
        return 0
    }
}

struct Embed: Decodable, Hashable {
    let url: String
    let server: String?
    let lang: String?
    let quality: String?

    var host: String? { URL(string: url)?.host }
}

struct Episode: Decodable, Identifiable, Hashable {
    let id: Int
    let title: String
    let overview: String
    let runtime: String?
    let seasonNumber: Int
    let episodeNumber: Int
    let stillPath: String?

    enum CodingKeys: String, CodingKey {
        case id = "_id", title, overview, runtime
        case seasonNumber = "season_number", episodeNumber = "episode_number", stillPath = "still_path"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        overview = (try? c.decode(String.self, forKey: .overview)) ?? ""
        runtime = (try? c.decodeIfPresent(String.self, forKey: .runtime)) ?? nil
        seasonNumber = (try? c.decode(Int.self, forKey: .seasonNumber)) ?? 0
        episodeNumber = (try? c.decode(Int.self, forKey: .episodeNumber)) ?? 0
        stillPath = (try? c.decodeIfPresent(String.self, forKey: .stillPath)) ?? nil
    }

    var stillURL: URL? {
        guard let stillPath, !stillPath.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w300" + stillPath)
    }

    var runtimeText: String? {
        guard let runtime, let value = Int(runtime), value > 0 else { return nil }
        return "\(value) min"
    }
}

/// Lo que el reproductor necesita para arrancar: el post (película o episodio) y un título.
struct PlaybackTarget: Hashable, Identifiable {
    let postId: Int
    let title: String

    var id: Int { postId }
}
