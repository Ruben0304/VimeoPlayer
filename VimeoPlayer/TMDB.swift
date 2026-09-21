import SwiftUI

/// Resuelve el logo de título (PNG transparente) de TMDB para una película/serie,
/// con cache en memoria por título para no repetir peticiones.
@MainActor
final class TMDBService {
    static let shared = TMDBService()

    private var cache: [String: URL?] = [:]
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

    private struct ImagesResponse: Decodable { let logos: [Logo] }

    /// `nil` si no hay clave configurada, no se encontró el título o no tiene logo.
    func logoURL(for item: CatalogItem) async -> URL? {
        guard !apiKey.isEmpty else { return nil }

        let cacheKey = "\(item.kind.rawValue)|\(item.originalTitle ?? item.displayTitle)|\(item.year ?? "")"
        if let cached = cache[cacheKey] { return cached }

        var titlesToTry = [item.originalTitle, item.displayTitle].compactMap { $0 }
        // Sin duplicar si son iguales.
        if titlesToTry.count == 2, titlesToTry[0] == titlesToTry[1] { titlesToTry.removeLast() }

        for title in titlesToTry {
            if let id = await searchID(kind: item.kind, title: title, year: item.year),
               let url = await bestLogo(kind: item.kind, id: id) {
                cache[cacheKey] = url
                return url
            }
        }
        cache[cacheKey] = URL?.none
        return nil
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

    private func bestLogo(kind: ContentKind, id: Int) async -> URL? {
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

        let best = decoded.logos
            .filter { !$0.filePath.lowercased().hasSuffix(".svg") }
            .sorted { lhs, rhs in
                let lhsRank = languageRank(lhs.iso6391), rhsRank = languageRank(rhs.iso6391)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                if lhs.voteAverage != rhs.voteAverage { return lhs.voteAverage > rhs.voteAverage }
                return lhs.width > rhs.width
            }
            .first

        guard let best else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500" + best.filePath)
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
        if let tmdbURL = await TMDBService.shared.logoURL(for: item) {
            withAnimation(.easeOut(duration: 0.25)) { state = .logo(tmdbURL) }
        } else if let webLogo = item.images.logoURL {
            withAnimation(.easeOut(duration: 0.25)) { state = .logo(webLogo) }
        }
        // Si no hay logo disponible, se queda el texto (ya mostrado desde el inicio).
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
                Text("Se usa para mostrar los logos de título en la portada y la ficha. Puedes conseguir una clave gratis en themoviedb.org. Se guarda solo en este equipo.")
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
