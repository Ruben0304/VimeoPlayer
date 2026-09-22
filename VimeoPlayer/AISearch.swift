import Foundation
import FoundationModels
import OSLog

/// Búsqueda con Apple Intelligence (modelo del dispositivo). El modelo no ve el catálogo:
/// propone títulos reales según lo que se le pide ("la del astronauta que cultiva papas
/// en Marte") y cada uno se busca en el catálogo local; solo se muestran los que están.
@MainActor
enum AISearch {
    static let log = Logger(subsystem: "com.ruben.lmomax", category: "AISearch")

    @Generable
    struct Guess {
        @Guide(description: "Películas o series recomendadas", .count(1...10))
        var titles: [Title]
    }

    @Generable
    struct Title {
        @Guide(description: "Nombres con los que se la conoce", .count(2...3))
        var names: [String]
        @Guide(description: "Año de estreno")
        var year: Int?
        @Guide(description: "true si es una serie o un anime, false si es una película")
        var isSeries: Bool
    }

    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    /// Carga el modelo antes de la primera búsqueda para que responda antes.
    static func prewarm() {
        guard isAvailable else { return }
        makeSession().prewarm()
    }

    /// Títulos del catálogo que corresponden a lo que propone el modelo, en su orden.
    static func run(_ query: String) async throws -> [CatalogItem] {
        let guess = try await makeSession().respond(to: query, generating: Guess.self).content
        for title in guess.titles {
            log.debug("\(query, privacy: .public) → \(title.names, privacy: .public) \(title.year ?? 0) serie=\(title.isSeries)")
        }
        await LocalCatalog.shared.load()

        var found: [CatalogItem] = []
        var seen = Set<Int>()
        for title in guess.titles {
            if Task.isCancelled { break }
            if let item = await find(title), seen.insert(item.id).inserted { found.append(item) }
        }
        return found
    }

    private static func makeSession() -> LanguageModelSession {
        LanguageModelSession(instructions: """
            The person's locale is \(Locale.current.identifier).
            Eres un recomendador de películas y series. Por cada una, da 2 o 3 nombres con los que se la conoce.
            """)
    }

    /// El título en el catálogo: primero por nombre exacto, tipo y año (±1); si el modelo se
    /// equivocó de año o de tipo, con la búsqueda de siempre, pero solo si el nombre coincide.
    private static func find(_ title: Title) async -> CatalogItem? {
        let names = title.names.filter { !$0.isEmpty }
        if let item = LocalCatalog.shared.match(names: names, year: title.year.map(String.init), isMovie: !title.isSeries) {
            return item
        }
        let wanted = Set(names.map(\.searchFolded))
        for name in names {
            let hits = await LocalCatalog.shared.search(name, limit: 5)
            if let item = hits.first(where: { hit in
                hit.kind.isEpisodic == title.isSeries
                    && [hit.displayTitle, hit.originalTitle].compactMap { $0 }.contains { wanted.contains($0.searchFolded) }
            }) {
                return item
            }
        }
        return nil
    }
}
