import AppIntents
import CoreSpotlight

// MARK: - Película o serie

/// Una película o serie para Siri. Si está en lamovie lleva su `CatalogItem`; si no, lo
/// que se sabe de TMDB, para poder contestar "todavía no está" y "dónde verla".
struct TitleEntity: IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Película o serie"
    static let defaultQuery = TitleQuery()

    /// "lm-123" (lamovie) o "tmdb-m-456" / "tmdb-t-456" (película / serie de TMDB).
    let id: String
    let name: String
    let kind: ContentKind
    let year: String?
    let posterURL: URL?
    let catalogItem: CatalogItem?
    let suggestion: TitleSuggestion?

    init(item: CatalogItem) {
        id = "lm-\(item.id)"
        name = item.displayTitle
        kind = item.kind
        year = item.year
        posterURL = item.images.posterURL
        catalogItem = item
        suggestion = nil
    }

    init(suggestion: TitleSuggestion) {
        id = "tmdb-\(suggestion.kind.isEpisodic ? "t" : "m")-\(suggestion.id)"
        name = suggestion.title
        kind = suggestion.kind
        year = suggestion.year
        posterURL = suggestion.posterURL
        catalogItem = nil
        self.suggestion = suggestion
    }

    var isOnLaMovie: Bool { catalogItem != nil }

    /// Todos los nombres con los que se le conoce.
    var names: [String] {
        if let catalogItem { return [name, catalogItem.originalTitle].compactMap { $0 } }
        return suggestion?.allNames ?? [name]
    }

    var displayRepresentation: DisplayRepresentation {
        let meta = [kind.label, year].compactMap { $0 }.joined(separator: " · ")
        return DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(meta)",
            image: posterURL.map { DisplayRepresentation.Image(url: $0) }
        )
    }

    /// Solo lo que hay en lamovie va a Spotlight.
    var hideInSpotlight: Bool { !isOnLaMovie }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.contentDescription = catalogItem?.overview
        attributes.alternateNames = Array(names.dropFirst())
        attributes.keywords = [kind.label, "LaMovie"]
        return attributes
    }
}

@MainActor
extension TitleEntity {
    /// Títulos de TMDB que Siri ya encontró, para no volver a pedirlos al resolver su id.
    private static var remembered: [String: TitleEntity] = [:]

    static func resolve(_ id: String) async -> TitleEntity? {
        let parts = id.split(separator: "-")
        if parts.count == 2, parts[0] == "lm", let number = Int(parts[1]) {
            await LocalCatalog.shared.load()
            return LocalCatalog.shared.items.first { $0.id == number }.map(TitleEntity.init(item:))
        }
        if parts.count == 3, parts[0] == "tmdb", let number = Int(parts[2]) {
            if let known = remembered[id] { return known }
            let suggestion = await TMDBService.shared.suggestion(tmdbID: number, isMovie: parts[1] == "m")
            return suggestion.map(TitleEntity.init(suggestion:))
        }
        return nil
    }

    /// El mismo título en lamovie si ya llegó (mismo nombre, tipo y año ±1); si no, él mismo.
    func inCatalog() -> TitleEntity {
        guard let suggestion,
              let item = LocalCatalog.shared.match(names: suggestion.allNames, year: suggestion.year,
                                                   isMovie: !suggestion.kind.isEpisodic) else { return self }
        return TitleEntity(item: item)
    }

    /// Plataformas por país (JustWatch vía TMDB), las mismas que muestra la ficha.
    func streamingDetails() async -> TMDBDetails? {
        if let catalogItem { return await TMDBService.shared.details(for: catalogItem) }
        if let suggestion { return await TMDBService.shared.details(tmdbID: suggestion.id, kind: suggestion.kind) }
        return nil
    }

    fileprivate static func remember(_ entity: TitleEntity) {
        if !entity.isOnLaMovie { remembered[entity.id] = entity }
    }
}

struct TitleQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [TitleEntity.ID]) async throws -> [TitleEntity] {
        var found: [TitleEntity] = []
        for id in identifiers {
            if let entity = await TitleEntity.resolve(id) { found.append(entity) }
        }
        return found
    }

    /// Lo que se le dice a Siri se busca igual que en la pestaña Buscar (`CatalogSearch`):
    /// primero lo que hay en lamovie y después los títulos de TMDB que aún no están.
    @MainActor
    func entities(matching string: String) async throws -> [TitleEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, let outcome = await CatalogSearch.run(query) else { return [] }

        var results = outcome.items.prefix(6).map(TitleEntity.init(item:))
        var seen = Set(results.map(\.id))
        for suggestion in outcome.suggestions {
            let entity = TitleEntity(suggestion: suggestion).inCatalog()
            if seen.insert(entity.id).inserted {
                TitleEntity.remember(entity)
                results.append(entity)
            }
        }
        // Si alguno se llama exactamente así, solo esos: Siri no pregunta "¿cuál?" sin necesidad.
        let wanted = query.searchFolded
        let exact = results.filter { $0.names.contains { $0.searchFolded == wanted } }
        return exact.isEmpty ? results : exact
    }

    /// Lo último que llegó a lamovie (también alimenta las frases de Siri con título).
    @MainActor
    func suggestedEntities() async throws -> [TitleEntity] {
        await LocalCatalog.shared.load()
        return LocalCatalog.shared.items.sorted { $0.id > $1.id }.prefix(20).map(TitleEntity.init(item:))
    }
}

/// Mete el catálogo en Spotlight (y así en el índice semántico que usa Siri) cuando cambia.
@MainActor
enum TitleSpotlightIndex {
    private static let signatureKey = "spotlightCatalogSignature"

    static func refresh() async {
        LaMovieShortcuts.updateAppShortcutParameters()

        let items = LocalCatalog.shared.items
        guard let top = items.map(\.id).max() else { return }
        let signature = "\(items.count)-\(top)"
        guard UserDefaults.standard.string(forKey: signatureKey) != signature else { return }

        let entities = items.map(TitleEntity.init(item:))
        let index = CSSearchableIndex(name: "LaMovie")
        do {
            for start in stride(from: 0, to: entities.count, by: 500) {
                try await index.indexAppEntities(Array(entities[start..<min(start + 500, entities.count)]))
            }
            UserDefaults.standard.set(signature, forKey: signatureKey)
        } catch {
            // Se reintenta la próxima vez que se abra la app.
        }
    }
}

// MARK: - País

/// Un país para "¿en qué plataformas está en España?".
struct CountryEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "País"
    static let defaultQuery = CountryQuery()

    /// Código ISO ("ES").
    let id: String

    var name: String { [String: StreamingAvailability].countryName(id) }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    /// Nombres con los que se le puede pedir, sin tildes ni mayúsculas.
    fileprivate var spokenNames: [String] {
        [name, Locale(identifier: "en").localizedString(forRegionCode: id) ?? "", id]
            .map(\.searchFolded).filter { !$0.isEmpty }
    }

    /// El país elegido en "Dónde ver" de la ficha o, si no, el del dispositivo.
    static var current: CountryEntity {
        CountryEntity(id: UserDefaults.standard.string(forKey: "streamingCountry")
                      ?? Locale.current.region?.identifier ?? "US")
    }

    static var all: [CountryEntity] {
        Locale.Region.isoRegions
            .map(\.identifier)
            .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
            .map(CountryEntity.init(id:))
    }
}

struct CountryQuery: EntityStringQuery {
    private static let aliases = [
        "usa": "US", "eeuu": "US", "ee uu": "US", "estados unidos": "US",
        "uk": "GB", "inglaterra": "GB", "gran bretana": "GB",
    ]

    func entities(for identifiers: [CountryEntity.ID]) async throws -> [CountryEntity] {
        identifiers.map(CountryEntity.init(id:))
    }

    func entities(matching string: String) async throws -> [CountryEntity] {
        let wanted = string.searchFolded
        if let code = Self.aliases[wanted] { return [CountryEntity(id: code)] }
        let all = CountryEntity.all
        let exact = all.filter { $0.spokenNames.contains(wanted) }
        if !exact.isEmpty { return exact }
        return all.filter { $0.spokenNames.contains { $0.hasPrefix(wanted) } }
    }

    func suggestedEntities() async throws -> [CountryEntity] {
        let current = CountryEntity.current
        let common = ["ES", "MX", "AR", "CO", "CL", "PE", "US"].filter { $0 != current.id }
        return [current] + common.map(CountryEntity.init(id:))
    }
}

// MARK: - Plataforma

/// Plataformas por las que se puede preguntar. TMDB/JustWatch las nombra distinto según
/// el país ("Max", "HBO Max", "Max Amazon Channel"…), así que se comparan por nombre.
enum StreamingPlatform: String, AppEnum {
    case netflix, hboMax, primeVideo, disneyPlus, appleTV, paramountPlus, movistarPlus
    case skyShowtime, crunchyroll, filmin, mubi, plutoTV, vix

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Plataforma"

    static let caseDisplayRepresentations: [StreamingPlatform: DisplayRepresentation] = [
        .netflix: DisplayRepresentation(title: "Netflix"),
        .hboMax: DisplayRepresentation(title: "HBO Max", synonyms: ["Max", "HBO"]),
        .primeVideo: DisplayRepresentation(title: "Prime Video", synonyms: ["Amazon Prime", "Amazon Prime Video", "Amazon"]),
        .disneyPlus: DisplayRepresentation(title: "Disney+", synonyms: ["Disney Plus", "Disney"]),
        .appleTV: DisplayRepresentation(title: "Apple TV", synonyms: ["Apple TV+", "Apple TV Plus"]),
        .paramountPlus: DisplayRepresentation(title: "Paramount+", synonyms: ["Paramount Plus", "Paramount"]),
        .movistarPlus: DisplayRepresentation(title: "Movistar Plus+", synonyms: ["Movistar", "Movistar Plus"]),
        .skyShowtime: DisplayRepresentation(title: "SkyShowtime", synonyms: ["Sky Showtime"]),
        .crunchyroll: DisplayRepresentation(title: "Crunchyroll"),
        .filmin: DisplayRepresentation(title: "Filmin"),
        .mubi: DisplayRepresentation(title: "MUBI", synonyms: ["Mubi"]),
        .plutoTV: DisplayRepresentation(title: "Pluto TV", synonyms: ["Pluto"]),
        .vix: DisplayRepresentation(title: "ViX", synonyms: ["Vix"]),
    ]

    var name: String {
        switch self {
        case .netflix: "Netflix"
        case .hboMax: "HBO Max"
        case .primeVideo: "Prime Video"
        case .disneyPlus: "Disney+"
        case .appleTV: "Apple TV"
        case .paramountPlus: "Paramount+"
        case .movistarPlus: "Movistar Plus+"
        case .skyShowtime: "SkyShowtime"
        case .crunchyroll: "Crunchyroll"
        case .filmin: "Filmin"
        case .mubi: "MUBI"
        case .plutoTV: "Pluto TV"
        case .vix: "ViX"
        }
    }

    /// Cómo empieza el nombre de la plataforma en TMDB (ya pasado por `searchFolded`).
    private var prefixes: [String] {
        switch self {
        case .netflix: ["netflix"]
        case .hboMax: ["hbo max", "max", "hbo"]
        case .primeVideo: ["amazon prime video", "prime video"]
        case .disneyPlus: ["disney"]
        case .appleTV: ["apple tv"]
        case .paramountPlus: ["paramount"]
        case .movistarPlus: ["movistar"]
        case .skyShowtime: ["skyshowtime"]
        case .crunchyroll: ["crunchyroll"]
        case .filmin: ["filmin"]
        case .mubi: ["mubi"]
        case .plutoTV: ["pluto tv"]
        case .vix: ["vix"]
        }
    }

    func matches(_ provider: StreamingProvider) -> Bool {
        let name = provider.name.searchFolded
        return prefixes.contains { name == $0 || name.hasPrefix($0 + " ") }
    }
}
