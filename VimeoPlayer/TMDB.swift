import SwiftUI

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
}

/// Ficha de TMDB (sinopsis en español y reparto) para un título.
struct TMDBDetails: Equatable {
    var overview: String?
    var cast: [CastMember]
}

/// Resuelve portadas, sinopsis y reparto de TMDB para una película/serie,
/// con cache en memoria por título para no repetir peticiones.
@MainActor
final class TMDBService {
    static let shared = TMDBService()

    private var imagesCache: [String: TMDBImages] = [:]
    private var detailsCache: [String: TMDBDetails] = [:]
    private var apiKey: String { UserDefaults.standard.string(forKey: "tmdbKey") ?? "" }

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

    private struct DetailsPayload: Decodable { let overview: String?; let credits: CreditsPayload? }
    private struct CreditsPayload: Decodable { let cast: [CastEntry] }
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
        func best(_ logos: [Logo], excludeSVG: Bool) -> URL? {
            let sorted = logos
                .filter { !excludeSVG || !$0.filePath.lowercased().hasSuffix(".svg") }
                .sorted { lhs, rhs in
                    let lhsRank = languageRank(lhs.iso6391), rhsRank = languageRank(rhs.iso6391)
                    if lhsRank != rhsRank { return lhsRank < rhsRank }
                    if lhs.voteAverage != rhs.voteAverage { return lhs.voteAverage > rhs.voteAverage }
                    return lhs.width > rhs.width
                }
            guard let first = sorted.first else { return nil }
            return URL(string: "https://image.tmdb.org/t/p/w500" + first.filePath)
        }

        return TMDBImages(
            logo: best(decoded.logos, excludeSVG: true),
            poster: best(decoded.posters, excludeSVG: false),
            backdrop: best(decoded.backdrops, excludeSVG: false)
        )
    }

    private func fetchDetails(kind: ContentKind, id: Int) async -> TMDBDetails? {
        let isMovie = kind == .movies
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(isMovie ? "movie" : "tv")/\(id)")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "language", value: "es-ES"),
            URLQueryItem(name: "append_to_response", value: "credits"),
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
        return TMDBDetails(overview: decoded.overview, cast: cast)
    }
}

/// Logo de título con degradación: TMDB → logo propio de la web → texto.
struct TitleLogo: View {
    let item: CatalogItem
    var textFont: Font = .system(size: 40, weight: .bold, design: .rounded)

    private enum LogoState: Equatable { case text, logo(URL) }
    @State private var state: LogoState = .text

    var body: some View {
        Group {
            switch state {
            case .text:
                fallbackText
            case .logo(let url):
                AsyncImage(url: url) { phase in
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
        .frame(maxWidth: 360, maxHeight: 130, alignment: .leading)
        .shadow(color: .black.opacity(0.5), radius: 8)
        .accessibilityLabel(item.displayTitle)
        .task(id: item.id) { await resolve() }
    }

    private var fallbackText: some View {
        Text(item.displayTitle)
            .font(textFont)
            .foregroundStyle(.white)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
    }

    private func resolve() async {
        if let tmdbURL = await TMDBService.shared.images(for: item).logo {
            withAnimation(.easeOut(duration: 0.25)) { state = .logo(tmdbURL) }
        } else if let webLogo = item.images.logoURL {
            withAnimation(.easeOut(duration: 0.25)) { state = .logo(webLogo) }
        }
        // Si no hay logo disponible, se queda el texto (ya mostrado desde el inicio).
    }
}

/// Insignia de calidad/formato, al estilo minimalista de las fichas de Apple TV:
/// texto en mayúsculas dentro de un recuadro con borde fino, sin relleno.
struct QualityBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(.white.opacity(0.55), lineWidth: 1)
            )
    }
}

/// Ajustes de la app; la clave de TMDB se guarda solo en este equipo (`UserDefaults`,
/// nunca en el repositorio).
struct SettingsView: View {
    @AppStorage("tmdbKey") private var tmdbKey: String = ""

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
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 180)
    }
}
