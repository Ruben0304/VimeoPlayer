import SwiftUI
import NaturalLanguage
import Translation

/// Reparto (actor + personaje) devuelto por TMDB.
struct CastMember: Identifiable, Hashable {
    let id: Int
    let name: String
    let character: String?
    let profileURL: URL?
}

/// Imágenes de TMDB resueltas para un título (logo, portada, fondo).
struct TMDBImages: Equatable {
    var logo: URL?
    var poster: URL?
    var backdrop: URL?
    /// Portada vertical sin texto rotulado (para el hero del móvil); `nil` si no hay ninguna así.
    var heroPoster: URL?
}

/// Tráiler de YouTube de un título.
struct TMDBTrailer: Equatable, Identifiable {
    let key: String
    let name: String
    var id: String { key }
}

/// Plataforma de streaming (logo incluido) donde está disponible un título.
struct StreamingProvider: Equatable, Identifiable {
    let id: Int
    let name: String
    let logoURL: URL?
}

/// Dónde ver un título en un país: por suscripción o gratis.
struct StreamingAvailability: Equatable {
    var link: URL?
    var subscription: [StreamingProvider] = []
    var free: [StreamingProvider] = []

    var isEmpty: Bool { subscription.isEmpty && free.isEmpty }
}

/// Ficha de TMDB (sinopsis en español y reparto) para un título.
struct TMDBDetails: Equatable {
    var overview: String?
    var cast: [CastMember]
    var tagline: String?
    var rating: Double?
    var voteCount: Int?
    var runtimeMinutes: Int?
    var releaseDate: String?
    var genres: [String] = []
    var countries: [String] = []
    var directors: [String] = []
    var writers: [String] = []
    var studios: [String] = []
    var originalLanguage: String?
    var seasonCount: Int?
    var episodeCount: Int?
    var trailer: TMDBTrailer?
    /// Código de país ISO ("ES", "MX"…) → plataformas. Datos de JustWatch.
    var streaming: [String: StreamingAvailability] = [:]
}

/// Resuelve portadas, sinopsis y reparto de TMDB para una película/serie,
/// con cache en memoria por título para no repetir peticiones.
@MainActor
final class TMDBService {
    static let shared = TMDBService()

    private var imagesCache: [String: TMDBImages] = [:]
    private var detailsCache: [String: TMDBDetails] = [:]
    private var apiKey: String {
        let stored = UserDefaults.standard.string(forKey: "tmdbKey") ?? ""
        return stored.isEmpty ? (Config.tmdbAPIKey ?? "") : stored
    }

    private struct SearchResult: Decodable { let id: Int }
    private struct SearchResponse: Decodable { let results: [SearchResult] }

    private struct Logo: Decodable {
        let filePath: String
        let iso6391: String?
        let voteAverage: Double
        let width: Int

        enum CodingKeys: String, CodingKey {
            case filePath = "file_path", iso6391 = "iso_639_1", voteAverage = "vote_average", width
        }
    }

    private struct ImagesResponse: Decodable { let logos: [Logo]; let posters: [Logo]; let backdrops: [Logo] }

    private struct NamedEntry: Decodable { let name: String }
    private struct CrewEntry: Decodable { let name: String; let job: String? }
    private struct DetailsPayload: Decodable {
        let overview: String?
        let credits: CreditsPayload?
        let tagline: String?
        let voteAverage: Double?
        let voteCount: Int?
        let runtime: Int?
        let episodeRunTime: [Int]?
        let releaseDate: String?
        let firstAirDate: String?
        let genres: [NamedEntry]?
        let productionCountries: [NamedEntry]?
        let productionCompanies: [NamedEntry]?
        let createdBy: [NamedEntry]?
        let originalLanguage: String?
        let numberOfSeasons: Int?
        let numberOfEpisodes: Int?
        let videos: VideosPayload?
        let watchProviders: ProvidersPayload?

        enum CodingKeys: String, CodingKey {
            case overview, credits, tagline, runtime, genres, videos
            case watchProviders = "watch/providers"
            case voteAverage = "vote_average", voteCount = "vote_count"
            case episodeRunTime = "episode_run_time"
            case releaseDate = "release_date", firstAirDate = "first_air_date"
            case productionCountries = "production_countries", productionCompanies = "production_companies"
            case createdBy = "created_by", originalLanguage = "original_language"
            case numberOfSeasons = "number_of_seasons", numberOfEpisodes = "number_of_episodes"
        }
    }
    private struct VideoEntry: Decodable {
        let key: String
        let site: String
        let type: String
        let name: String
        let official: Bool?
        let iso6391: String?
        enum CodingKeys: String, CodingKey { case key, site, type, name, official, iso6391 = "iso_639_1" }
    }
    private struct VideosPayload: Decodable { let results: [VideoEntry] }
    private struct ProviderEntry: Decodable {
        let providerId: Int
        let providerName: String
        let logoPath: String?
        enum CodingKeys: String, CodingKey { case providerId = "provider_id", providerName = "provider_name", logoPath = "logo_path" }
    }
    private struct CountryProviders: Decodable {
        let link: String?
        let flatrate: [ProviderEntry]?
        let free: [ProviderEntry]?
        let ads: [ProviderEntry]?
    }
    private struct ProvidersPayload: Decodable { let results: [String: CountryProviders] }
    private struct CreditsPayload: Decodable { let cast: [CastEntry]; let crew: [CrewEntry]? }
    private struct CastEntry: Decodable {
        let id: Int
        let name: String
        let character: String?
        let profilePath: String?

        enum CodingKeys: String, CodingKey { case id, name, character, profilePath = "profile_path" }
    }

    private func cacheKey(for item: CatalogItem) -> String {
        "\(item.kind.rawValue)|\(item.originalTitle ?? item.displayTitle)|\(item.year ?? "")"
    }

    private func titlesToTry(for item: CatalogItem) -> [String] {
        var titles = [item.originalTitle, item.displayTitle].compactMap { $0 }
        // Sin duplicar si son iguales.
        if titles.count == 2, titles[0] == titles[1] { titles.removeLast() }
        return titles
    }

    /// Logo, portada y fondo de TMDB. Valores `nil` si no hay clave configurada,
    /// no se encontró el título o no tiene esa imagen.
    func images(for item: CatalogItem) async -> TMDBImages {
        guard !apiKey.isEmpty else { return TMDBImages() }

        let cacheKey = cacheKey(for: item)
        if let cached = imagesCache[cacheKey] { return cached }

        for title in titlesToTry(for: item) {
            if let id = await searchID(kind: item.kind, title: title, year: item.year),
               let images = await fetchImages(kind: item.kind, id: id) {
                imagesCache[cacheKey] = images
                return images
            }
        }
        let empty = TMDBImages()
        imagesCache[cacheKey] = empty
        return empty
    }

    /// Sinopsis (en español) y reparto de TMDB. `nil` si no hay clave configurada
    /// o no se encontró el título.
    func details(for item: CatalogItem) async -> TMDBDetails? {
        guard !apiKey.isEmpty else { return nil }

        let cacheKey = cacheKey(for: item)
        if let cached = detailsCache[cacheKey] { return cached }

        for title in titlesToTry(for: item) {
            if let id = await searchID(kind: item.kind, title: title, year: item.year),
               let details = await fetchDetails(kind: item.kind, id: id) {
                detailsCache[cacheKey] = details
                return details
            }
        }
        return nil
    }

    /// Compatibilidad: solo el logo (usado por `TitleLogo`).
    func logoURL(for item: CatalogItem) async -> URL? {
        await images(for: item).logo
    }

    private func searchID(kind: ContentKind, title: String, year: String?) async -> Int? {
        let isMovie = kind == .movies
        var components = URLComponents(string: "https://api.themoviedb.org/3/search/" + (isMovie ? "movie" : "tv"))!
        var query = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: title),
        ]
        if let year {
            query.append(URLQueryItem(name: isMovie ? "year" : "first_air_date_year", value: year))
        }
        components.queryItems = query

        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data) else { return nil }
        return decoded.results.first?.id
    }

    private func fetchImages(kind: ContentKind, id: Int) async -> TMDBImages? {
        let isMovie = kind == .movies
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(isMovie ? "movie" : "tv")/\(id)/images")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "include_image_language", value: "es,en,null"),
        ]

        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(ImagesResponse.self, from: data) else { return nil }

        // Preferencia: idioma (es > en > sin idioma > otros), luego voto, luego ancho.
        func languageRank(_ lang: String?) -> Int {
            switch lang {
            case "es": 0
            case "en": 1
            case nil: 2
            default: 3
            }
        }
        func best(_ logos: [Logo], excludeSVG: Bool, textless: Bool = false, size: String = "w500") -> URL? {
            // Fondos: se prefieren los "sin idioma" (sin título rotulado en la imagen), porque
            // el logo se pone aparte encima; solo si no hay ninguno se usa uno con texto.
            let textlessOnly = logos.filter { $0.iso6391 == nil }
            let pool = textless && !textlessOnly.isEmpty ? textlessOnly : logos
            let sorted = pool
                .filter { !excludeSVG || !$0.filePath.lowercased().hasSuffix(".svg") }
                .sorted { lhs, rhs in
                    let lhsRank = languageRank(lhs.iso6391), rhsRank = languageRank(rhs.iso6391)
                    if lhsRank != rhsRank { return lhsRank < rhsRank }
                    if lhs.voteAverage != rhs.voteAverage { return lhs.voteAverage > rhs.voteAverage }
                    return lhs.width > rhs.width
                }
            guard let first = sorted.first else { return nil }
            return URL(string: "https://image.tmdb.org/t/p/\(size)" + first.filePath)
        }

        return TMDBImages(
            logo: best(decoded.logos, excludeSVG: true),
            poster: best(decoded.posters, excludeSVG: false),
            backdrop: best(decoded.backdrops, excludeSVG: false, textless: true, size: "w1280"),
            heroPoster: best(decoded.posters.filter { $0.iso6391 == nil }, excludeSVG: true, size: "original")
        )
    }

    private func fetchDetails(kind: ContentKind, id: Int) async -> TMDBDetails? {
        let isMovie = kind == .movies
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(isMovie ? "movie" : "tv")/\(id)")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "language", value: "es-ES"),
            URLQueryItem(name: "append_to_response", value: "credits,videos,watch/providers"),
            URLQueryItem(name: "include_video_language", value: "es,en,null"),
        ]

        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(DetailsPayload.self, from: data) else { return nil }

        var cast: [CastMember] = []
        for entry in (decoded.credits?.cast ?? []).prefix(12) {
            let profileURL = entry.profilePath.flatMap { URL(string: "https://image.tmdb.org/t/p/w185" + $0) }
            cast.append(CastMember(id: entry.id, name: entry.name, character: entry.character, profileURL: profileURL))
        }

        let crew = decoded.credits?.crew ?? []
        func names(_ jobs: Set<String>) -> [String] {
            var seen = Set<String>()
            return crew.filter { jobs.contains($0.job ?? "") }.map(\.name).filter { seen.insert($0).inserted }
        }
        let directors = isMovie ? names(["Director"]) : (decoded.createdBy ?? []).map(\.name)
        let language = decoded.originalLanguage.flatMap { Locale(identifier: "es").localizedString(forLanguageCode: $0) }

        // Tráiler: oficial y en español primero, luego inglés; si no hay tráiler, un teaser.
        func languageRank(_ lang: String?) -> Int { lang == "es" ? 0 : lang == "en" ? 1 : 2 }
        let videos = (decoded.videos?.results ?? []).filter { $0.site == "YouTube" }
        func bestVideo(_ type: String) -> VideoEntry? {
            videos.filter { $0.type == type }.min {
                if ($0.official ?? false) != ($1.official ?? false) { return $0.official ?? false }
                return languageRank($0.iso6391) < languageRank($1.iso6391)
            }
        }
        let trailer = (bestVideo("Trailer") ?? bestVideo("Teaser")).map { TMDBTrailer(key: $0.key, name: $0.name) }

        func providers(_ entries: [ProviderEntry]?) -> [StreamingProvider] {
            (entries ?? []).map {
                StreamingProvider(id: $0.providerId, name: $0.providerName,
                                  logoURL: $0.logoPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w300" + $0) })
            }
        }
        var streaming: [String: StreamingAvailability] = [:]
        for (country, entry) in decoded.watchProviders?.results ?? [:] {
            let availability = StreamingAvailability(
                link: entry.link.flatMap(URL.init(string:)),
                subscription: providers(entry.flatrate),
                free: providers((entry.free ?? []) + (entry.ads ?? []))
            )
            if !availability.isEmpty { streaming[country] = availability }
        }

        return TMDBDetails(
            overview: decoded.overview,
            cast: cast,
            tagline: decoded.tagline.flatMap { $0.isEmpty ? nil : $0 },
            rating: decoded.voteAverage.flatMap { $0 > 0 ? $0 : nil },
            voteCount: decoded.voteCount,
            runtimeMinutes: decoded.runtime ?? decoded.episodeRunTime?.first,
            releaseDate: decoded.releaseDate ?? decoded.firstAirDate,
            genres: (decoded.genres ?? []).map(\.name),
            countries: (decoded.productionCountries ?? []).map(\.name),
            directors: Array(directors.prefix(3)),
            writers: Array(names(["Screenplay", "Writer", "Story"]).prefix(3)),
            studios: Array((decoded.productionCompanies ?? []).map(\.name).prefix(3)),
            originalLanguage: language,
            seasonCount: decoded.numberOfSeasons,
            episodeCount: decoded.numberOfEpisodes,
            trailer: trailer,
            streaming: streaming
        )
    }
}

// MARK: - Traducción de la búsqueda

/// Traduce al inglés lo que el usuario escribe (en el propio equipo, con el framework de
/// Traducción de Apple), para encontrar títulos que solo existen con su nombre original.
@MainActor
final class QueryTranslator: ObservableObject {
    static let shared = QueryTranslator()

    /// Se rellena cuando falta descargar el idioma; la vista lo usa para pedir la descarga.
    @Published var downloadConfig: TranslationSession.Configuration?
    private var cache: [String: String?] = [:]
    private let english = Locale.Language(identifier: "en")

    /// La traducción al inglés, o `nil` si ya está en inglés, no se pudo traducir o
    /// queda igual que el original.
    func english(_ text: String) async -> String? {
        let key = text.lowercased()
        if let cached = cache[key] { return cached }

        let result = await translate(text)
        cache[key] = result
        return result
    }

    private func translate(_ text: String) async -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let detected = recognizer.dominantLanguage?.rawValue ?? "es"
        if detected == "en" { return nil }

        let availability = LanguageAvailability()
        var source = Locale.Language(identifier: detected)
        var status = await availability.status(from: source, to: english)
        if status == .unsupported {
            // Con frases cortas la detección falla a menudo; se asume español.
            source = Locale.Language(identifier: "es")
            status = await availability.status(from: source, to: english)
        }

        switch status {
        case .installed:
            let session = TranslationSession(installedSource: source, target: english)
            guard let translated = try? await session.translate(text).targetText else { return nil }
            let clean = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.caseInsensitiveCompare(text) == .orderedSame ? nil : clean
        case .supported:
            // Falta el paquete de idioma: se pide la descarga y esta vez se busca sin traducir.
            downloadConfig = TranslationSession.Configuration(source: source, target: english)
            return nil
        default:
            return nil
        }
    }
}

// MARK: - Sugerencias de búsqueda

/// Un título de TMDB que coincide con lo buscado, con todos los nombres con los que se
/// le conoce (español, original, inglés, alternativos) para relanzar la búsqueda.
struct TitleSuggestion: Identifiable, Equatable {
    let id: Int
    let kind: ContentKind
    let title: String
    let year: String?
    let posterURL: URL?
    /// Nombres distintos de `title`, sin repetidos, del más útil al menos.
    let aliases: [String]

    /// Todos los nombres buscables, empezando por el principal.
    var allNames: [String] { [title] + aliases }
}

extension TMDBService {
    private struct MultiResult: Decodable {
        let id: Int
        let mediaType: String
        let title: String?
        let name: String?
        let originalTitle: String?
        let originalName: String?
        let releaseDate: String?
        let firstAirDate: String?
        let posterPath: String?
        let genreIds: [Int]?
        let originalLanguage: String?

        enum CodingKeys: String, CodingKey {
            case id, title, name
            case mediaType = "media_type", originalTitle = "original_title", originalName = "original_name"
            case releaseDate = "release_date", firstAirDate = "first_air_date", posterPath = "poster_path"
            case genreIds = "genre_ids", originalLanguage = "original_language"
        }
    }
    private struct MultiResponse: Decodable { let results: [MultiResult] }

    private struct AltTitle: Decodable { let title: String }
    private struct AltTitles: Decodable {
        let titles: [AltTitle]?   // películas
        let results: [AltTitle]?  // series
    }
    private struct TranslationData: Decodable { let title: String?; let name: String? }
    private struct Translation: Decodable { let iso6391: String; let data: TranslationData
        enum CodingKeys: String, CodingKey { case iso6391 = "iso_639_1", data }
    }
    private struct Translations: Decodable { let translations: [Translation] }
    private struct NamesPayload: Decodable {
        let alternativeTitles: AltTitles?
        let translations: Translations?
        enum CodingKeys: String, CodingKey { case alternativeTitles = "alternative_titles", translations }
    }

    /// Títulos de TMDB que encajan con `query`, con sus nombres alternativos. Vacío si no
    /// hay clave configurada o TMDB no responde.
    func suggestions(for query: String, limit: Int = 4) async -> [TitleSuggestion] {
        guard !apiKey.isEmpty else { return [] }
        let key = apiKey

        let top = await Self.searchMulti(query, key: key)

        return await withTaskGroup(of: (Int, TitleSuggestion?).self) { group in
            for (index, result) in top.prefix(limit).enumerated() {
                group.addTask { (index, await Self.makeSuggestion(result, key: key)) }
            }
            var ordered: [(Int, TitleSuggestion)] = []
            for await (index, suggestion) in group {
                if let suggestion { ordered.append((index, suggestion)) }
            }
            return ordered.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private nonisolated static func searchMulti(_ query: String, key: String) async -> [MultiResult] {
        var components = URLComponents(string: "https://api.themoviedb.org/3/search/multi")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "language", value: "es-ES"),
            URLQueryItem(name: "include_adult", value: "false"),
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(MultiResponse.self, from: data) else { return [] }
        return decoded.results.filter { $0.mediaType == "movie" || $0.mediaType == "tv" }
    }

    private nonisolated static func makeSuggestion(_ result: MultiResult, key: String) async -> TitleSuggestion? {
        let isMovie = result.mediaType == "movie"
        guard let title = (isMovie ? result.title : result.name), !title.isEmpty else { return nil }
        let original = isMovie ? result.originalTitle : result.originalName
        let date = isMovie ? result.releaseDate : result.firstAirDate

        var names: [String] = []
        if let original { names.append(original) }

        var components = URLComponents(string: "https://api.themoviedb.org/3/\(isMovie ? "movie" : "tv")/\(result.id)")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "append_to_response", value: "alternative_titles,translations"),
        ]
        if let url = components.url,
           let (data, response) = try? await URLSession.shared.data(from: url),
           let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
           let payload = try? JSONDecoder().decode(NamesPayload.self, from: data) {
            // Traducciones al inglés/español/portugués primero, luego los alternativos.
            let wanted = ["en", "es", "pt", "fr", "it", "de", "ja"]
            let translated = (payload.translations?.translations ?? [])
                .filter { wanted.contains($0.iso6391) }
                .sorted { (wanted.firstIndex(of: $0.iso6391) ?? 99) < (wanted.firstIndex(of: $1.iso6391) ?? 99) }
                .compactMap { $0.data.title ?? $0.data.name }
            names += translated
            names += (payload.alternativeTitles?.titles ?? payload.alternativeTitles?.results ?? []).map(\.title)
        }

        // Sin vacíos ni repetidos (ignorando mayúsculas y tildes), y distintos del principal.
        func fold(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        var seen: Set<String> = [fold(title)]
        let aliases = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert(fold($0)).inserted }

        return TitleSuggestion(
            id: result.id,
            kind: isMovie ? .movies : .tvshows,
            title: title,
            year: date.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil },
            posterURL: result.posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w185" + $0) },
            aliases: Array(aliases.prefix(5))
        )
    }
}

/// Logo de título con degradación: TMDB → logo propio de la web → texto.
struct TitleLogo: View {
    let item: CatalogItem
    var textFont: Font = .system(size: 40, weight: .bold, design: .rounded)
    /// Permite diferir la petición (p. ej. páginas del hero que aún no toca mostrar).
    var enabled = true
    var alignment: Alignment = .leading

    private enum LogoState: Equatable { case text, logo(URL) }
    @State private var state: LogoState = .text

    var body: some View {
        Group {
            switch state {
            case .text:
                fallbackText
            case .logo(let url):
                CachedAsyncImage(url: url, category: .logo) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    case .failure:
                        fallbackText
                    case .empty:
                        Color.clear
                    @unknown default:
                        Color.clear
                    }
                }
            }
        }
        .frame(maxWidth: 360, maxHeight: 130, alignment: alignment)
        .shadow(color: .black.opacity(0.5), radius: 8)
        .accessibilityLabel(item.displayTitle)
        .task(id: TaskKey(id: item.id, enabled: enabled)) { await resolve() }
    }

    private var fallbackText: some View {
        Text(item.displayTitle)
            .font(textFont)
            .foregroundStyle(.white)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .multilineTextAlignment(alignment == .center ? .center : .leading)
    }

    private struct TaskKey: Hashable { let id: Int; let enabled: Bool }

    /// Solo el logo de TMDB; si no hay, se queda el título en texto.
    private func resolve() async {
        guard enabled else { return }
        state = .text
        if let tmdbURL = await TMDBService.shared.images(for: item).logo {
            withAnimation(.easeOut(duration: 0.25)) { state = .logo(tmdbURL) }
        }
    }
}

/// Insignia de calidad/formato, al estilo de las fichas de Apple TV: la principal va
/// rellena (gris claro, texto oscuro) y las demás con borde fino.
struct QualityBadge: View {
    let label: String
    var filled = false

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .tracking(0.3)
            .foregroundStyle(filled ? Color.black.opacity(0.85) : .white.opacity(0.85))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background {
                if filled {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white.opacity(0.78))
                }
            }
            .overlay {
                if !filled {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(.white.opacity(0.6), lineWidth: 1)
                }
            }
    }
}

/// Ajustes de la app; la clave de TMDB se guarda solo en este equipo (`UserDefaults`,
/// nunca en el repositorio).
struct SettingsView: View {
    @AppStorage("tmdbKey") private var tmdbKey: String = ""
    @State private var usage: [ImageCategory: CacheUsage]?
    @State private var selected: Set<ImageCategory> = []
    @State private var age = AgeOption.any
    @State private var confirmClear = false
    @State private var lastFreed: Int64?

    /// Cuánto tiempo sin usarse para que una imagen se borre.
    private enum AgeOption: String, CaseIterable, Identifiable {
        case any, day, week, month
        var id: String { rawValue }
        var label: String {
            switch self {
            case .any: "Todas, sin importar la antigüedad"
            case .day: "Sin usar desde hace más de 1 día"
            case .week: "Sin usar desde hace más de 1 semana"
            case .month: "Sin usar desde hace más de 1 mes"
            }
        }
        var seconds: TimeInterval? {
            switch self {
            case .any: nil
            case .day: 86_400
            case .week: 7 * 86_400
            case .month: 30 * 86_400
            }
        }
    }

    private static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private func size(_ bytes: Int64) -> String { Self.bytes.string(fromByteCount: bytes) }
    private var totalBytes: Int64 { usage?.values.reduce(0) { $0 + $1.bytes } ?? 0 }
    private var totalCount: Int { usage?.values.reduce(0) { $0 + $1.count } ?? 0 }

    var body: some View {
        Form {
            Section {
                SecureField("Clave de API de TMDB (v3)", text: $tmdbKey)
                Text("Se usa para mostrar los logos de título, las portadas y la ficha (sinopsis y reparto). Puedes conseguir una clave gratis en themoviedb.org. Se guarda solo en este equipo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("TMDB")
            }

            Section {
                if let usage {
                    LabeledContent("Total") {
                        Text("\(size(totalBytes)) · \(totalCount) imágenes").fontWeight(.semibold)
                    }
                    breakdownBar(usage)
                    ForEach(ImageCategory.allCases) { category in
                        categoryRow(category, usage[category] ?? CacheUsage())
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            } header: {
                Text("Caché de imágenes")
            } footer: {
                Text("Marca las categorías que quieras limpiar. Lo borrado se vuelve a descargar cuando haga falta.")
            }

            Section {
                Picker("Borrar", selection: $age) {
                    ForEach(AgeOption.allCases) { Text($0.label).tag($0) }
                }
                HStack {
                    Button(selected.count == ImageCategory.allCases.count ? "Quitar selección" : "Seleccionar todo") {
                        selected = selected.count == ImageCategory.allCases.count ? [] : Set(ImageCategory.allCases)
                    }
                    Spacer()
                    if let lastFreed {
                        Text("Liberados \(size(lastFreed))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Borrar selección", role: .destructive) {
                        if age == .any { confirmClear = true } else { clear() }
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 660)
        .task { usage = await ImageCache.shared.usage() }
        .confirmationDialog("¿Borrar las imágenes de \(selected.count) \(selected.count == 1 ? "categoría" : "categorías")?",
                            isPresented: $confirmClear) {
            Button("Borrar", role: .destructive) { clear() }
        } message: {
            Text(selected.sorted { $0.label < $1.label }.map(\.label).joined(separator: ", "))
        }
    }

    /// Barra apilada: qué parte del espacio se lleva cada categoría.
    private func breakdownBar(_ usage: [ImageCategory: CacheUsage]) -> some View {
        GeometryReader { proxy in
            let total = max(totalBytes, 1)
            HStack(spacing: 2) {
                ForEach(ImageCategory.allCases) { category in
                    let bytes = usage[category]?.bytes ?? 0
                    if bytes > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(category.color)
                            .frame(width: max(4, proxy.size.width * CGFloat(bytes) / CGFloat(total)))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 10)
        .background(.quaternary, in: Capsule())
        .clipShape(Capsule())
    }

    private func categoryRow(_ category: ImageCategory, _ usage: CacheUsage) -> some View {
        let isSelected = selected.contains(category)
        return Button {
            if isSelected { selected.remove(category) } else { selected.insert(category) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Circle().fill(category.color).frame(width: 9, height: 9)
                Label(category.label, systemImage: category.icon)
                Spacer()
                Text("\(usage.count)")
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                Text(size(usage.bytes))
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func clear() {
        let categories = selected
        let seconds = age.seconds
        Task {
            lastFreed = await ImageCache.shared.clear(categories, olderThan: seconds)
            usage = await ImageCache.shared.usage()
        }
    }
}
