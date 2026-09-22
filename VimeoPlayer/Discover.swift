import SwiftUI

// MARK: - Listas de TMDB

/// Un título tal como sale en las listas de TMDB (tendencias, plataformas, filmografías…).
struct TMDBTitle: Hashable, Identifiable {
    let tmdbID: Int
    let isMovie: Bool
    let title: String
    let originalTitle: String?
    /// Solo si la lista se pidió en inglés (lo que usa la búsqueda de portadas de Apple TV).
    let englishTitle: String?
    let date: String?
    let posterPath: String?
    let popularity: Double

    var id: String { "\(isMovie ? "m" : "t")\(tmdbID)" }
    var year: String? { date.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil } }
    var posterURL: URL? { posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w342" + $0) } }
    var names: [String] { [originalTitle, title].compactMap { $0 } }
}

/// Resultado crudo de TMDB: películas usan `title`/`release_date` y series `name`/`first_air_date`.
private struct RawTitle: Decodable {
    let id: Int
    let mediaType: String?
    let title: String?
    let name: String?
    let originalTitle: String?
    let originalName: String?
    let releaseDate: String?
    let firstAirDate: String?
    let posterPath: String?
    let popularity: Double?
    let character: String?
    let job: String?
    let genreIds: [Int]?

    enum CodingKeys: String, CodingKey {
        case id, title, name, popularity, character, job
        case mediaType = "media_type", originalTitle = "original_title", originalName = "original_name"
        case releaseDate = "release_date", firstAirDate = "first_air_date", posterPath = "poster_path"
        case genreIds = "genre_ids"
    }

    /// `hint` indica el tipo cuando la lista no lo trae (las de `discover` son de un solo tipo).
    func resolved(isMovie hint: Bool?, english: Bool) -> TMDBTitle? {
        let isMovie: Bool
        switch mediaType {
        case "movie": isMovie = true
        case "tv": isMovie = false
        case nil:
            guard let hint else { return nil }
            isMovie = hint
        default: return nil  // Personas, etc.
        }
        guard let shown = (isMovie ? title : name) ?? title ?? name, !shown.isEmpty else { return nil }
        return TMDBTitle(
            tmdbID: id,
            isMovie: isMovie,
            title: shown,
            originalTitle: isMovie ? originalTitle : originalName,
            englishTitle: english ? shown : nil,
            date: isMovie ? releaseDate : firstAirDate,
            posterPath: posterPath,
            popularity: popularity ?? 0
        )
    }
}

private struct TitlePage: Decodable { let results: [RawTitle] }

@MainActor
enum TMDBLists {
    /// Las `pages` primeras páginas de `path`, en orden. Sin `language` la lista llega en inglés.
    static func titles(_ path: String, _ params: [String: String] = [:], isMovie: Bool? = nil,
                       pages: Int = 1, language: String? = nil) async -> [TMDBTitle] {
        let key = TMDBService.shared.apiKey
        guard !key.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, [TMDBTitle]).self) { group in
            for page in 1...max(1, pages) {
                group.addTask {
                    (page, await fetchPage(path, params, page: page, key: key, isMovie: isMovie, language: language))
                }
            }
            var pages: [(Int, [TMDBTitle])] = []
            for await page in group { pages.append(page) }
            return pages.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
    }

    private nonisolated static func fetchPage(_ path: String, _ params: [String: String], page: Int, key: String,
                                              isMovie: Bool?, language: String?) async -> [TMDBTitle] {
        guard var components = URLComponents(string: "https://api.themoviedb.org/3/" + path) else { return [] }
        var query = [URLQueryItem(name: "api_key", value: key), URLQueryItem(name: "page", value: String(page))]
        if let language { query.append(URLQueryItem(name: "language", value: language)) }
        query += params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = query
        guard let url = components.url,
              let decoded = await URLSession.shared.fetchJSON(TitlePage.self, from: url).value else { return [] }
        return decoded.results.compactMap { $0.resolved(isMovie: isMovie, english: language == nil) }
    }
}

extension LocalCatalog {
    /// Los títulos de TMDB que se pueden ver en lamovie, en el mismo orden y sin repetir.
    func available(_ titles: [TMDBTitle], excluding: Set<Int> = []) -> [CatalogItem] {
        var seen = excluding
        var result: [CatalogItem] = []
        for title in titles {
            guard let item = match(names: title.names, year: title.year, isMovie: title.isMovie),
                  seen.insert(item.id).inserted else { continue }
            TMDBService.shared.remember(item, tmdbID: title.tmdbID, englishTitle: title.englishTitle)
            result.append(item)
        }
        return result
    }
}

// MARK: - Filas del inicio

/// Filas del inicio que salen de TMDB, con solo lo que está en lamovie.
@MainActor
final class DiscoverViewModel: ObservableObject {
    @Published private(set) var trending: Shelf?
    @Published private(set) var becauseYouWatched: [Shelf] = []
    @Published private(set) var providers: [Shelf] = []

    private var loaded = false
    /// Menos de esto no llena una fila: mejor no mostrarla.
    private let minimumItems = 6

    private struct Provider {
        let ids: String
        let name: String
    }

    private let platforms = [
        Provider(ids: "8", name: "Netflix"),
        Provider(ids: "119", name: "Prime Video"),
        Provider(ids: "337", name: "Disney+"),
        Provider(ids: "1899|384", name: "Max"),
        Provider(ids: "350", name: "Apple TV+"),
    ]

    /// `seeds`: lo último visto, para "Porque viste…". `force` vuelve a pedirlo todo.
    func load(seeds: [CatalogItem], region: String, force: Bool = false) async {
        guard force || !loaded else { return }
        loaded = true
        await LocalCatalog.shared.load()

        async let trending: Void = loadTrending()
        async let because: Void = loadBecause(seeds: seeds)
        async let providers: Void = loadProviders(region: region)
        _ = await (trending, because, providers)
    }

    private func loadTrending() async {
        let titles = await TMDBLists.titles("trending/all/week", pages: 3)
        let items = LocalCatalog.shared.available(titles)
        trending = items.count >= minimumItems ? Shelf(id: "tmdb-trending", title: "Tendencias de la semana", items: items) : nil
    }

    /// Solo las filas "Porque viste…" (las recomendaciones ya pedidas salen de la caché).
    func refreshBecause(seeds: [CatalogItem]) async {
        await LocalCatalog.shared.load()
        await loadBecause(seeds: seeds)
    }

    private func loadBecause(seeds: [CatalogItem]) async {
        var seen = Set<Int>()
        let picked = seeds.filter { $0.kind != .wwe && seen.insert($0.id).inserted }.prefix(2)
        var shelves: [Shelf] = []
        for seed in picked {
            let items = await SimilarTitles.load(for: seed)
            if items.count >= minimumItems {
                shelves.append(Shelf(id: "because-\(seed.id)", title: "Porque viste «\(seed.displayTitle)»", items: items))
            }
        }
        becauseYouWatched = shelves
    }

    private func loadProviders(region: String) async {
        let rows = await withTaskGroup(of: (Int, Shelf?).self) { group in
            for (position, platform) in platforms.enumerated() {
                group.addTask { (position, await self.providerShelf(platform, region: region)) }
            }
            var rows: [(Int, Shelf?)] = []
            for await row in group { rows.append(row) }
            return rows.sorted { $0.0 < $1.0 }.compactMap(\.1)
        }
        providers = rows
    }

    private func providerShelf(_ platform: Provider, region: String) async -> Shelf? {
        func fetch(_ region: String) async -> [TMDBTitle] {
            let params = ["with_watch_providers": platform.ids, "watch_region": region, "sort_by": "popularity.desc"]
            async let movies = TMDBLists.titles("discover/movie", params, isMovie: true, pages: 2)
            async let series = TMDBLists.titles("discover/tv", params, isMovie: false, pages: 2)
            return await (movies + series).sorted { $0.popularity > $1.popularity }
        }
        var titles = await fetch(region)
        // Hay países sin datos de plataformas en TMDB; entonces se usa el catálogo de EE. UU.
        if titles.isEmpty, region != "US" { titles = await fetch("US") }
        let items = LocalCatalog.shared.available(titles)
        guard items.count >= minimumItems else { return nil }
        return Shelf(id: "provider-\(platform.name)", title: "Populares en \(platform.name)", items: items)
    }
}

// MARK: - Similares

/// Títulos parecidos según TMDB (recomendaciones y, si faltan, "similares") que están en
/// lamovie. Se recuerdan por título para no repetir peticiones al volver a una ficha.
@MainActor
enum SimilarTitles {
    private static var cache: [Int: [CatalogItem]] = [:]

    static func load(for item: CatalogItem) async -> [CatalogItem] {
        if let cached = cache[item.id] { return cached }
        guard item.kind != .wwe else { return [] }
        await LocalCatalog.shared.load()
        guard let tmdbID = await TMDBService.shared.tmdbID(for: item) else { return [] }

        let isMovie = !item.kind.isEpisodic
        let base = "\(isMovie ? "movie" : "tv")/\(tmdbID)"
        var items = LocalCatalog.shared.available(
            await TMDBLists.titles(base + "/recommendations", isMovie: isMovie, pages: 2), excluding: [item.id])
        // Los títulos poco conocidos apenas tienen recomendaciones; "similares" (por género
        // y palabras clave) rellena.
        if items.count < 8 {
            let more = await TMDBLists.titles(base + "/similar", isMovie: isMovie, pages: 1)
            items += LocalCatalog.shared.available(more, excluding: Set(items.map(\.id)).union([item.id]))
        }
        let result = Array(items.prefix(20))
        cache[item.id] = result
        return result
    }
}

// MARK: - Avísame cuando esté

/// Un título de TMDB que aún no está en lamovie y del que se quiere aviso.
struct WantedTitle: Codable, Hashable, Identifiable {
    let tmdbID: Int
    let isMovie: Bool
    let title: String
    let names: [String]
    let year: String?
    let posterURL: URL?

    var id: String { "\(isMovie ? "m" : "t")\(tmdbID)" }

    init(_ title: TMDBTitle) {
        tmdbID = title.tmdbID
        isMovie = title.isMovie
        self.title = title.title
        names = title.names
        year = title.year
        posterURL = title.posterURL
    }

    init(_ suggestion: TitleSuggestion) {
        tmdbID = suggestion.id
        isMovie = !suggestion.kind.isEpisodic
        title = suggestion.title
        names = suggestion.allNames
        year = suggestion.year
        posterURL = suggestion.posterURL
    }
}

/// Lista de "Avísame": cada vez que el catálogo se carga o se actualiza se mira si ya
/// llegó alguno; los que llegan pasan a "De tu lista, ya disponible" hasta que se abren.
@MainActor
final class WantedStore: ObservableObject {
    static let shared = WantedStore()

    @Published private(set) var wanted: [WantedTitle]
    @Published private(set) var arrived: [CatalogItem]

    private let wantedKey = "wantedTitles"
    private let arrivedKey = "wantedArrived"

    private init() {
        let defaults = UserDefaults.standard
        wanted = defaults.data(forKey: wantedKey).flatMap { try? JSONDecoder().decode([WantedTitle].self, from: $0) } ?? []
        arrived = defaults.data(forKey: arrivedKey).flatMap { try? JSONDecoder().decode([CatalogItem].self, from: $0) } ?? []
    }

    func isWanted(_ id: String) -> Bool { wanted.contains { $0.id == id } }

    func toggle(_ title: WantedTitle) {
        if let position = wanted.firstIndex(where: { $0.id == title.id }) {
            wanted.remove(at: position)
        } else {
            wanted.insert(title, at: 0)
        }
        persist()
    }

    func remove(_ title: WantedTitle) {
        wanted.removeAll { $0.id == title.id }
        persist()
    }

    func check(against index: LocalSearchIndex) {
        var found: [CatalogItem] = []
        wanted.removeAll { title in
            guard let item = index.match(names: title.names, year: title.year, isMovie: title.isMovie) else { return false }
            found.append(item)
            return true
        }
        guard !found.isEmpty else { return }
        let known = Set(arrived.map(\.id))
        arrived = found.filter { !known.contains($0.id) } + arrived
        persist()
    }

    /// Al abrir la ficha, deja de salir en "De tu lista, ya disponible".
    func dismiss(itemID: Int) {
        guard arrived.contains(where: { $0.id == itemID }) else { return }
        arrived.removeAll { $0.id == itemID }
        persist()
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(wanted), forKey: wantedKey)
        defaults.set(try? JSONEncoder().encode(arrived), forKey: arrivedKey)
    }
}

/// Botón de campana para apuntarse (o desapuntarse) al aviso de un título.
struct WantedButton: View {
    let title: WantedTitle
    @ObservedObject private var store = WantedStore.shared

    var body: some View {
        let on = store.isWanted(title.id)
        Button {
            withAnimation(.snappy) { store.toggle(title) }
        } label: {
            Label(on ? "Te avisaré" : "Avísame", systemImage: on ? "bell.fill" : "bell")
                .font(.caption.weight(.semibold))
                .foregroundStyle(on ? .yellow : .white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .pointerCursor()
        .accessibilityHint("Aparecerá en el inicio cuando llegue a lamovie")
    }
}

/// Ajustes: los títulos apuntados a "Avísame".
struct WantedSettingsSection: View {
    @ObservedObject private var store = WantedStore.shared

    var body: some View {
        Section {
            if store.wanted.isEmpty {
                Text("Nada todavía. Toca «Avísame» en un título que no esté en lamovie.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.wanted) { title in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title.title)
                        Text([title.isMovie ? "Película" : "Serie", title.year].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Quitar", systemImage: "bell.slash") { store.remove(title) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Avísame cuando esté")
        } footer: {
            Text("Cuando llegan a lamovie aparecen en el inicio, en «De tu lista, ya disponible».")
        }
    }
}

// MARK: - Actores

/// Ruta de navegación a la página de una persona del reparto.
struct PersonRoute: Hashable {
    let id: Int
    let name: String
    let profileURL: URL?
}

private struct PersonPayload: Decodable {
    let biography: String?
    let knownForDepartment: String?
    let birthday: String?
    let deathday: String?
    let placeOfBirth: String?
    let combinedCredits: Credits?

    struct Credits: Decodable {
        let cast: [RawTitle]?
        let crew: [RawTitle]?
    }

    enum CodingKeys: String, CodingKey {
        case biography, birthday, deathday
        case knownForDepartment = "known_for_department", placeOfBirth = "place_of_birth"
        case combinedCredits = "combined_credits"
    }
}

/// Filmografía de un actor o director: lo que se puede ver en lamovie y, aparte, lo que no
/// (con "Avísame").
struct PersonView: View {
    let route: PersonRoute

    private enum Phase { case loading, loaded, failed }

    @State private var phase = Phase.loading
    @State private var biography: String?
    @State private var subtitle: String?
    @State private var available: [CatalogItem] = []
    @State private var missing: [TMDBTitle] = []
    @State private var expanded = false

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    switch phase {
                    case .loading:
                        ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.top, 40)
                    case .failed:
                        Label("No se pudo cargar la filmografía", systemImage: "wifi.exclamationmark")
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    case .loaded:
                        availableSection
                        missingSection
                    }
                }
                .padding(.vertical, 24)
            }
        }
        .navigationTitle(route.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: route.id) { await load() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            Circle()
                .fill(Brand.card)
                .frame(width: 110, height: 110)
                .overlay {
                    PosterImage(url: route.profileURL, category: .cast)
                        .aspectRatio(contentMode: .fill)
                }
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(route.name)
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }
                if let biography {
                    Text(biography)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(expanded ? nil : 4)
                        .padding(.top, 4)
                    Button(expanded ? "Menos" : "Más") { withAnimation { expanded.toggle() } }
                        .font(.callout.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(.horizontal, HomeLayout.shelfHorizontalPadding)
    }

    @ViewBuilder
    private var availableSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(available.isEmpty ? "Nada suyo en lamovie todavía" : "Para ver en lamovie", count: available.count)
            if !available.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: HomeLayout.gridMinimumCardWidth), spacing: HomeLayout.cardSpacing, alignment: .top)],
                          alignment: .leading, spacing: HomeLayout.cardSpacing) {
                    ForEach(available) { item in
                        PosterCard(item: item, width: HomeLayout.gridCardWidth)
                    }
                }
                .padding(.horizontal, HomeLayout.shelfHorizontalPadding)
            }
        }
    }

    @ViewBuilder
    private var missingSection: some View {
        if !missing.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("No está en lamovie", count: missing.count)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: HomeLayout.cardSpacing) {
                        ForEach(missing) { title in
                            MissingTitleCard(title: title)
                        }
                    }
                    .padding(.horizontal, HomeLayout.shelfHorizontalPadding)
                }
            }
        }
    }

    private func sectionTitle(_ text: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))
            if count > 0 {
                Text("\(count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, HomeLayout.shelfHorizontalPadding)
    }

    private func load() async {
        let key = TMDBService.shared.apiKey
        guard !key.isEmpty,
              var components = URLComponents(string: "https://api.themoviedb.org/3/person/\(route.id)") else {
            phase = .failed
            return
        }
        components.queryItems = [
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "language", value: "es-ES"),
            URLQueryItem(name: "append_to_response", value: "combined_credits"),
        ]
        guard let url = components.url,
              let payload = await URLSession.shared.fetchJSON(PersonPayload.self, from: url).value else {
            phase = .failed
            return
        }

        biography = payload.biography.flatMap { $0.isEmpty ? nil : $0 }
        subtitle = Self.subtitle(payload)

        // Sin programas de entrevistas ni noticias, ni apariciones "como sí mismo".
        let skippedGenres: Set<Int> = [10767, 10763]
        let selfRoles = ["self", "himself", "herself", "sí mismo", "sí misma", "él mismo", "ella misma"]
        let crewJobs: Set<String> = ["Director", "Creator", "Screenplay", "Writer"]
        let cast = (payload.combinedCredits?.cast ?? []).filter { credit in
            let role = credit.character?.lowercased() ?? ""
            return !selfRoles.contains { role.contains($0) } && Set(credit.genreIds ?? []).isDisjoint(with: skippedGenres)
        }
        let crew = (payload.combinedCredits?.crew ?? []).filter { crewJobs.contains($0.job ?? "") }
        var seen = Set<String>()
        let titles = (cast + crew)
            .compactMap { $0.resolved(isMovie: nil, english: false) }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.popularity > $1.popularity }

        available = LocalCatalog.shared.available(titles)
        let availableIDs = Set(titles.filter { title in
            LocalCatalog.shared.match(names: title.names, year: title.year, isMovie: title.isMovie) != nil
        }.map(\.id))
        missing = Array(titles.filter { !availableIDs.contains($0.id) && $0.posterPath != nil }.prefix(30))
        phase = .loaded
    }

    private static func subtitle(_ payload: PersonPayload) -> String? {
        let department: String? = switch payload.knownForDepartment {
        case "Acting": "Interpretación"
        case "Directing": "Dirección"
        case "Writing": "Guion"
        case "Production": "Producción"
        default: payload.knownForDepartment
        }
        var born: String?
        if let birthday = payload.birthday, birthday.count >= 4 {
            born = "Nacimiento: " + String(birthday.prefix(4))
            if let place = payload.placeOfBirth, !place.isEmpty { born! += " · " + place }
        }
        let parts = [department, born].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Póster de TMDB de un título que no está en lamovie, con su botón "Avísame".
private struct MissingTitleCard: View {
    let title: TMDBTitle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Brand.card
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay {
                    PosterImage(url: title.posterURL)
                        .aspectRatio(contentMode: .fill)
                        .clipped()
                        .opacity(0.55)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .bottom) {
                    WantedButton(title: WantedTitle(title))
                        .padding(8)
                }
            Text(title.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
            Text([title.isMovie ? "Película" : "Serie", title.year].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(width: HomeLayout.cardWidth)
    }
}
