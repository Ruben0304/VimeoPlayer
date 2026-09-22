import Foundation

/// La búsqueda de la pestaña Buscar, sin nada de interfaz. La usan `SearchViewModel` y
/// Siri (`TitleQuery`), así que preguntar a Siri encuentra exactamente lo mismo que buscar
/// en la app: catálogo local, traducción al inglés y, si no hay nada, los otros nombres
/// del título según TMDB.
@MainActor
enum CatalogSearch {
    struct Outcome {
        var items: [CatalogItem] = []
        /// Títulos de TMDB afines a lo buscado, con sus nombres alternativos.
        var suggestions: [TitleSuggestion] = []
        /// Nombre alternativo con el que se encontraron resultados cuando lo buscado no dio ninguno.
        var fallbackName: String?
        /// Títulos cuya trama encaja con lo buscado.
        var related: [CatalogItem] = []
        /// No se pudo consultar el catálogo (ni local ni lamovie).
        var failed = false
    }

    /// Busca `query` (ya sin espacios sobrantes). `onLocal` recibe los resultados locales
    /// (por título y por trama) en cuanto están, antes de esperar a TMDB. `nil` si la
    /// tarea se canceló.
    static func run(
        _ query: String,
        onLocal: (_ hits: [CatalogItem], _ related: [CatalogItem]) -> Void = { _, _ in }
    ) async -> Outcome? {
        // TMDB (traducción y sugerencias) va en paralelo y nunca retrasa los resultados:
        // lo escrito se busca de inmediato y lo demás se suma cuando llega.
        async let extras = Self.extras(for: query)
        let raw = await Result { try await Self.find(query) }
        if Task.isCancelled { return nil }
        var outcome = Outcome()
        outcome.related = await LocalCatalog.shared.plotSearch(query)
        if Task.isCancelled { return nil }

        if case .success(let hits) = raw, !hits.isEmpty {
            onLocal(hits, outcome.related)
            outcome.items = hits
            let (translated, found) = await extras
            if Task.isCancelled { return nil }
            outcome.suggestions = found
            if let translated, translated.lowercased() != query.lowercased(),
               let more = try? await Self.find(translated), !Task.isCancelled {
                var seen = Set(hits.map(\.id))
                outcome.items += more.filter { seen.insert($0.id).inserted }
            }
            return outcome
        }
        onLocal([], outcome.related)

        // Sin resultados con lo escrito: se prueba la traducción y, si hace falta, los otros nombres.
        let (translated, found) = await extras
        if Task.isCancelled { return nil }
        outcome.suggestions = found
        var failed = false
        if case .failure = raw { failed = true }
        if let translated, translated.lowercased() != query.lowercased() {
            if let hits = try? await Self.find(translated) { outcome.items = hits; failed = false }
            if Task.isCancelled { return nil }
        }
        if outcome.items.isEmpty {
            var tried = Set([query, translated].compactMap { $0?.lowercased() })
            for name in found.flatMap(\.allNames) where name.count >= 3 && tried.insert(name.lowercased()).inserted {
                if let hits = try? await Self.find(name), !hits.isEmpty {
                    outcome.items = hits
                    outcome.fallbackName = name
                    failed = false
                    break
                }
                if Task.isCancelled { return nil }
            }
        }
        if Task.isCancelled { return nil }
        outcome.failed = failed
        return outcome
    }

    /// Busca en el catálogo local; solo si no se pudo cargar se pregunta a lamovie.
    private static func find(_ query: String) async throws -> [CatalogItem] {
        await LocalCatalog.shared.load()
        if LocalCatalog.shared.items.isEmpty { return try await LaMovieAPI.search(query) }
        return await LocalCatalog.shared.search(query)
    }

    /// Traducción al inglés de lo escrito y sugerencias de TMDB para ambas variantes.
    private static func extras(for query: String) async -> (String?, [TitleSuggestion]) {
        let translated = await QueryTranslator.shared.english(query)
        let queries = [query] + [translated].compactMap { $0 }
        return (translated, await suggestions(for: queries))
    }

    /// Sugerencias de TMDB para todas las variantes, sin repetir y con las de lo escrito primero.
    private static func suggestions(for queries: [String]) async -> [TitleSuggestion] {
        var lists: [[TitleSuggestion]] = []
        await withTaskGroup(of: (Int, [TitleSuggestion]).self) { group in
            for (index, query) in queries.enumerated() {
                group.addTask { (index, await TMDBService.shared.suggestions(for: query)) }
            }
            var indexed: [(Int, [TitleSuggestion])] = []
            for await entry in group { indexed.append(entry) }
            lists = indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }
        var seen = Set<Int>()
        return Array(lists.flatMap { $0 }.filter { seen.insert($0.id * 10 + ($0.kind.isEpisodic ? 2 : 1)).inserted }.prefix(5))
    }
}
