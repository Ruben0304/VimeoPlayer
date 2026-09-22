import SwiftUI
import NaturalLanguage

/// Catálogo completo de lamovie guardado en el equipo, para buscar sin conexión.
///
/// La app trae una instantánea comprimida (`LaMovieCatalog.deflate`, generada con
/// `scripts/build_catalog.py`). Al actualizar solo se piden las páginas con títulos
/// nuevos, y en disco se guardan únicamente esos títulos añadidos (el "delta").
@MainActor
final class LocalCatalog: ObservableObject {
    static let shared = LocalCatalog()

    enum UpdateStatus: Equatable {
        case idle, updating, done(added: Int), failed
    }

    @Published private(set) var items: [CatalogItem] = []
    /// Fecha de la instantánea incluida en la app.
    @Published private(set) var snapshotDate: Date?
    /// Última vez que se buscaron títulos nuevos (nil si nunca).
    @Published private(set) var lastCheckedAt: Date?
    /// Títulos añadidos desde la instantánea.
    @Published private(set) var addedCount = 0
    @Published private(set) var status = UpdateStatus.idle
    /// Títulos que no estaban la última vez que se abrió la app (más nuevos primero).
    @Published private(set) var newSinceLastVisit: [CatalogItem] = []

    /// Buscar novedades solo al abrir la app, como mucho una vez al día.
    static let autoUpdateKey = "catalogAutoUpdate"
    private static let lastVisitKey = "catalogLastVisitTopID"
    /// Id más alto que había en la visita anterior (los ids de lamovie crecen con cada alta).
    private var previousTopID: Int?

    private(set) var index = LocalSearchIndex(items: [])
    private var delta: [CatalogItem] = []
    private var loadTask: Task<Void, Never>?

    private struct Snapshot: Codable {
        var generatedAt: Date
        var posts: [CatalogItem]
    }

    private struct Delta: Codable {
        var checkedAt: Date?
        var posts: [CatalogItem]
    }

    private nonisolated static let deltaURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LaMovieCatalog-added.json")
    }()

    private nonisolated static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Carga la instantánea y los añadidos (una sola vez; las demás llamadas esperan a la primera).
    func load() async {
        if let loadTask { return await loadTask.value }
        let task = Task {
            let (snapshot, delta, index) = await Task.detached(priority: .userInitiated) {
                let snapshot = Self.readSnapshot()
                let delta = Self.readDelta()
                let known = Set(snapshot?.posts.map(\.id) ?? [])
                // Lo que una versión nueva de la app ya trae en la instantánea sale del delta.
                let pending = delta.posts.filter { !known.contains($0.id) }
                let merged = pending + (snapshot?.posts ?? [])
                return (snapshot, Delta(checkedAt: delta.checkedAt, posts: pending), LocalSearchIndex(items: merged))
            }.value
            self.snapshotDate = snapshot?.generatedAt
            self.delta = delta.posts
            self.lastCheckedAt = delta.checkedAt
            self.addedCount = delta.posts.count
            self.index = index
            self.items = index.items
            self.previousTopID = UserDefaults.standard.object(forKey: Self.lastVisitKey) as? Int
            self.refreshVisitState()
            WantedStore.shared.check(against: index)
        }
        loadTask = task
        await task.value
    }

    /// Recalcula "Añadido desde tu última visita" y deja apuntado lo que hay ahora
    /// para la próxima vez. La primera vez no hay con qué comparar.
    private func refreshVisitState() {
        guard let top = items.map(\.id).max() else { return }
        if let previousTopID {
            newSinceLastVisit = Array(items.filter { $0.id > previousTopID }.sorted { $0.id > $1.id }.prefix(30))
        } else {
            previousTopID = top
        }
        UserDefaults.standard.set(top, forKey: Self.lastVisitKey)
    }

    /// Busca novedades si está activado y no se ha hecho en las últimas 20 horas.
    func updateIfStale() async {
        await load()
        let enabled = UserDefaults.standard.object(forKey: Self.autoUpdateKey) as? Bool ?? true
        guard enabled else { return }
        if let lastCheckedAt, Date().timeIntervalSince(lastCheckedAt) < 20 * 3600 { return }
        await update()
    }

    /// El título del catálogo que corresponde a uno de TMDB (mismo nombre, tipo y año ±1).
    func match(names: [String], year: String?, isMovie: Bool) -> CatalogItem? {
        index.match(names: names, year: year, isMovie: isMovie)
    }

    /// Resultados por título para `query`, del más al menos parecido.
    func search(_ query: String, limit: Int = 60) async -> [CatalogItem] {
        await load()
        let index = index
        return await Task.detached(priority: .userInitiated) { index.search(query, limit: limit) }.value
    }

    /// Títulos cuya sinopsis trata de lo buscado ("tiburón asesino", "viaje en el tiempo").
    func plotSearch(_ query: String, limit: Int = 30) async -> [CatalogItem] {
        await load()
        let index = index
        return await Task.detached(priority: .userInitiated) { index.searchPlot(query, limit: limit) }.value
    }

    /// Pide a lamovie los títulos añadidos desde la última vez. Por cada tipo se leen
    /// páginas (de más reciente a más antiguo) hasta dar con una que ya se conocía entera.
    func update() async {
        guard status != .updating else { return }
        await load()
        status = .updating

        let known = Set(items.map(\.id))
        do {
            let fresh = try await withThrowingTaskGroup(of: [CatalogItem].self) { group in
                for kind in ContentKind.allCases {
                    group.addTask { try await Self.newItems(of: kind, known: known) }
                }
                var all: [CatalogItem] = []
                for try await items in group { all += items }
                return all
            }
            var seen = Set<Int>()
            let added = fresh.filter { seen.insert($0.id).inserted }.sorted { $0.id > $1.id }

            delta = added + delta
            lastCheckedAt = Date()
            let saved = Delta(checkedAt: lastCheckedAt, posts: delta)
            await Task.detached(priority: .utility) { Self.write(saved) }.value

            if !added.isEmpty {
                let merged = added + items
                index = await Task.detached(priority: .userInitiated) { LocalSearchIndex(items: merged) }.value
                items = index.items
                refreshVisitState()
                WantedStore.shared.check(against: index)
            }
            addedCount = delta.count
            status = .done(added: added.count)
        } catch {
            status = .failed
        }
    }

    nonisolated static func newItems(of kind: ContentKind, known: Set<Int>) async throws -> [CatalogItem] {
        var found: [CatalogItem] = []
        let perPage = 30  // Máximo que devuelve la API por página.
        for page in 1...500 {
            let posts: [CatalogItem]
            do {
                posts = try await LaMovieAPI.listing(kind, orderBy: "latest", perPage: perPage, page: page)
            } catch APIError.empty {
                break
            }
            let unknown = posts.filter { !known.contains($0.id) }
            found += unknown
            if unknown.isEmpty || posts.count < perPage { break }
        }
        return found
    }

    // MARK: - Disco

    private nonisolated static func readSnapshot() -> Snapshot? {
        guard let url = Bundle.main.url(forResource: "LaMovieCatalog", withExtension: "deflate"),
              let packed = try? Data(contentsOf: url),
              let json = try? (packed as NSData).decompressed(using: .zlib) as Data else { return nil }
        return try? decoder.decode(Snapshot.self, from: json)
    }

    private nonisolated static func readDelta() -> Delta {
        guard let data = try? Data(contentsOf: deltaURL),
              let delta = try? decoder.decode(Delta.self, from: data) else { return Delta(checkedAt: nil, posts: []) }
        return delta
    }

    private nonisolated static func write(_ delta: Delta) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(delta) else { return }
        try? FileManager.default.createDirectory(at: deltaURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: deltaURL, options: .atomic)
    }
}

// MARK: - Búsqueda por título

/// Índice en memoria para buscar por título: sin mayúsculas ni tildes, por palabras
/// sueltas (en cualquier orden, basta el principio de cada una) y tolerante a erratas.
/// También busca por la trama (ver `searchPlot`).
struct LocalSearchIndex: Sendable {
    let items: [CatalogItem]
    private let entries: [Entry]
    private let plot: PlotIndex
    /// Nombre normalizado → posiciones en `items`, para emparejar títulos de TMDB.
    private let byName: [String: [Int]]

    private struct Entry: Sendable {
        /// Título en español y título original, ya normalizados.
        let names: [String]
        /// Los mismos nombres sin espacios.
        let joined: [String]
        let tokens: [[[UInt8]]]
        let year: String?
    }

    init(items: [CatalogItem]) {
        self.items = items
        entries = items.map { item in
            var names = [item.displayTitle.searchFolded]
            if let original = item.originalTitle?.searchFolded, !original.isEmpty, original != names[0] {
                names.append(original)
            }
            return Entry(names: names, joined: names.map { $0.replacingOccurrences(of: " ", with: "") },
                         tokens: names.map(Self.tokens), year: item.year)
        }
        plot = PlotIndex(items: items)
        var byName: [String: [Int]] = [:]
        for (position, entry) in entries.enumerated() {
            for name in entry.names { byName[name, default: []].append(position) }
        }
        self.byName = byName
    }

    /// Mismo nombre (cualquiera de `names`: original, en español, en inglés…), tipo compatible
    /// y año a ±1. Si hay varios, el de año más cercano; sin año, solo si no hay dudas.
    func match(names: [String], year: String?, isMovie: Bool) -> CatalogItem? {
        var candidates: [Int] = []
        for name in names {
            let folded = name.searchFolded
            guard !folded.isEmpty else { continue }
            for position in byName[folded] ?? [] where !candidates.contains(position) {
                let kind = items[position].kind
                if isMovie ? kind == .movies : kind.isEpisodic { candidates.append(position) }
            }
        }
        let wanted = year.flatMap { Int($0) }
        func gap(_ position: Int) -> Int? {
            guard let wanted, let own = entries[position].year.flatMap({ Int($0) }) else { return nil }
            return abs(own - wanted)
        }
        let dated = candidates.compactMap { position in gap(position).map { (position, $0) } }.filter { $0.1 <= 1 }
        if let best = dated.min(by: { $0.1 < $1.1 }) { return items[best.0] }
        let undated = candidates.filter { gap($0) == nil }
        return undated.count == 1 ? items[undated[0]] : nil
    }

    func searchPlot(_ query: String, limit: Int) -> [CatalogItem] {
        plot.search(query, limit: limit).map { items[$0] }
    }

    func search(_ raw: String, limit: Int) -> [CatalogItem] {
        let query = raw.searchFolded
        guard !query.isEmpty else { return [] }
        var queryTokens = Self.tokens(query)
        // Un año suelto ("dune 2021") filtra en vez de buscarse en el título.
        let year = queryTokens.count > 1 ? queryTokens.last.flatMap { $0.count == 4 && $0.allSatisfy { $0 >= 48 && $0 <= 57 } ? String(decoding: $0, as: UTF8.self) : nil } : nil
        if year != nil { queryTokens.removeLast() }
        let text = year == nil ? query : queryTokens.map { String(decoding: $0, as: UTF8.self) }.joined(separator: " ")
        let joinedText = text.replacingOccurrences(of: " ", with: "")

        var scored: [(index: Int, score: Double)] = []
        for (index, entry) in entries.enumerated() {
            if let year, entry.year != year { continue }
            var best = 0.0
            for position in entry.names.indices {
                best = max(best, Self.score(text: text, joinedText: joinedText, tokens: queryTokens, name: entry.names[position],
                                            joinedName: entry.joined[position], nameTokens: entry.tokens[position]))
            }
            if best > 0 { scored.append((index, best)) }
        }
        // Si hay aciertos claros, las coincidencias por errata sobran.
        if scored.contains(where: { $0.score >= Self.typoScore + 100 }) {
            scored.removeAll { $0.score <= Self.typoScore + 100 }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return items[lhs.index].id > items[rhs.index].id  // A igualdad, lo más reciente.
        }
        return scored.prefix(limit).map { items[$0.index] }
    }

    private static func score(text: String, joinedText: String, tokens: [[UInt8]],
                              name: String, joinedName: String, nameTokens: [[UInt8]]) -> Double {
        // Cuanto más se parece la longitud, mejor: "Dune" antes que "Dune: Parte dos".
        let closeness = Double(text.count) / Double(max(name.count, text.count))
        if name == text { return 1000 }
        if name.hasPrefix(text) { return 800 + 100 * closeness }

        var missing = 0
        var typos = 0
        for token in tokens where !nameTokens.contains(where: { $0.starts(with: token) }) {
            missing += 1
            if token.count >= 4, nameTokens.contains(where: { isTypo(token, of: $0) }) { typos += 1 }
        }
        if missing == 0 { return 600 + 100 * closeness }
        if name.contains(text) { return 500 + 100 * closeness }
        // Sin espacios: "spiderman" encuentra "Spider-Man".
        if joinedText.count >= 4, joinedName.contains(joinedText) { return 450 + 100 * closeness }
        // Todas las palabras aparecen, alguna con una errata.
        if missing == typos { return typoScore + 100 * closeness }
        return 0
    }

    private static let typoScore = 300.0

    /// `token` es el principio de `word` con como mucho una errata (dos si es largo).
    private static func isTypo(_ token: [UInt8], of word: [UInt8]) -> Bool {
        let allowed = token.count >= 8 ? 2 : 1
        guard word.count >= token.count - allowed else { return false }
        // Se compara con el principio de la palabra, con algo de holgura por letras sobrantes o faltantes.
        for length in max(1, token.count - allowed)...min(word.count, token.count + allowed) {
            if distance(token, Array(word.prefix(length)), limit: allowed) <= allowed { return true }
        }
        return false
    }

    /// Distancia de edición (con transposiciones), cortando en cuanto supera `limit`.
    private static func distance(_ a: [UInt8], _ b: [UInt8], limit: Int) -> Int {
        if abs(a.count - b.count) > limit { return limit + 1 }
        var previous2 = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMin = current[0]
            for j in 1...max(1, b.count) where b.count > 0 {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, previous2[j - 2] + 1)
                }
                current[j] = value
                rowMin = min(rowMin, value)
            }
            if rowMin > limit { return limit + 1 }
            (previous2, previous, current) = (previous, current, previous2)
        }
        return previous[b.count]
    }

    private static func tokens(_ folded: String) -> [[UInt8]] {
        folded.split(separator: " ").map { Array($0.utf8) }
    }
}

// MARK: - Búsqueda por trama

/// Índice invertido de título y sinopsis, puntuado con BM25. Cada palabra de la consulta se
/// amplía con sus vecinas en los embeddings de palabras de Apple (en el propio equipo), así
/// "dinosaurios" también encuentra "jurásico" y "boxeador", "boxeo".
private struct PlotIndex: Sendable {
    private struct Posting: Sendable {
        let document: Int32
        let count: Float
    }

    private let postings: [String: [Posting]]
    private let lengths: [Float]
    private let averageLength: Float

    /// Palabras tan comunes que no dicen nada del argumento.
    private static let stopwords: Set<String> = [
        "que", "los", "las", "del", "por", "una", "uno", "unos", "unas", "con", "para", "sus", "como",
        "pero", "mas", "cuando", "esta", "este", "estos", "estas", "entre", "sobre", "tras", "hasta",
        "donde", "todo", "toda", "todos", "ser", "son", "han", "muy", "sin", "vez", "otro", "otra",
        "ella", "ellos", "ellas", "desde", "tiene", "cual", "dos", "sino", "les", "nos", "mismo", "hace",
        "pelicula", "peliculas", "serie", "series", "the", "and",
    ]

    /// Español: basta con el principio de la palabra para juntar plurales y variantes
    /// ("zombis"/"zombie", "robo"/"robos").
    private static func stem(_ word: Substring) -> String { String(word.prefix(6)) }

    private static func terms(_ text: String) -> [String] {
        text.searchFolded.split(separator: " ")
            .filter { $0.count >= 3 && !stopwords.contains(String($0)) }
            .map(stem)
    }

    init(items: [CatalogItem]) {
        var postings: [String: [Posting]] = [:]
        var lengths: [Float] = []
        lengths.reserveCapacity(items.count)
        for (document, item) in items.enumerated() {
            // El título cuenta doble: si el tema está en el nombre, pesa más.
            let title = Self.terms(item.displayTitle + " " + (item.originalTitle ?? ""))
            let terms = title + title + Self.terms(item.overview)
            var counts: [String: Float] = [:]
            for term in terms { counts[term, default: 0] += 1 }
            for (term, count) in counts {
                postings[term, default: []].append(Posting(document: Int32(document), count: count))
            }
            lengths.append(Float(terms.count))
        }
        self.postings = postings
        self.lengths = lengths
        averageLength = max(1, lengths.reduce(0, +) / Float(max(1, lengths.count)))
    }

    /// Índices de los documentos más afines, de mayor a menor.
    func search(_ query: String, limit: Int) -> [Int] {
        var weights: [String: Float] = [:]
        for word in query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let own = Self.terms(String(word))
            guard !own.isEmpty else { continue }
            for term in own { weights[term] = 1 }
            // Las vecinas suman, pero menos que la palabra escrita.
            for (neighbor, distance) in Self.words?.neighbors(for: String(word), maximumCount: 4) ?? [] where distance < 0.9 {
                for term in Self.terms(neighbor) where weights[term] == nil { weights[term] = 0.4 }
            }
        }
        guard !weights.isEmpty else { return [] }

        let total = Float(lengths.count)
        var scores: [Int32: Float] = [:]
        for (term, weight) in weights {
            guard let list = postings[term] else { continue }
            let idf = log(1 + (total - Float(list.count) + 0.5) / (Float(list.count) + 0.5))
            for posting in list {
                let tf = posting.count
                let norm = 1.2 * (0.25 + 0.75 * lengths[Int(posting.document)] / averageLength)
                scores[posting.document, default: 0] += weight * idf * tf * 2.2 / (tf + norm)
            }
        }
        guard let best = scores.values.max() else { return [] }
        // Lo que queda muy por debajo del mejor suele ser una coincidencia casual.
        return scores.filter { $0.value >= best * 0.45 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map { Int($0.key) }
    }

    /// Embeddings de palabras en español que trae el sistema (nil si no están disponibles).
    private nonisolated(unsafe) static let words = NLEmbedding.wordEmbedding(for: .spanish)
}

extension String {
    /// Minúsculas, sin tildes y con solo letras y números separados por un espacio,
    /// para comparar títulos ("Spider-Man: Sin camino" → "spider man sin camino").
    var searchFolded: String {
        let folded = decodingHTMLEntities.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var result = ""
        result.reserveCapacity(folded.count)
        var pendingSpace = false
        for character in folded {
            if character.isLetter || character.isNumber {
                if pendingSpace, !result.isEmpty { result.append(" ") }
                pendingSpace = false
                result.append(character)
            } else if character == "'" || character == "’" {
                continue  // "Ocean's" → "oceans"
            } else {
                pendingSpace = true
            }
        }
        return result
    }
}

// MARK: - Ajustes

/// Sección de Ajustes con el estado del catálogo local y el botón para actualizarlo.
struct CatalogSettingsSection: View {
    @ObservedObject private var catalog = LocalCatalog.shared
    @AppStorage(LocalCatalog.autoUpdateKey) private var autoUpdate = true

    var body: some View {
        Section {
            LabeledContent("Títulos") {
                Text(catalog.items.count.formatted())
                    .monospacedDigit()
            }
            if let snapshot = catalog.snapshotDate {
                LabeledContent("Incluidos con la app") {
                    Text(snapshot.formatted(date: .abbreviated, time: .omitted))
                }
            }
            if catalog.addedCount > 0 {
                LabeledContent("Añadidos después") {
                    Text(catalog.addedCount.formatted())
                        .monospacedDigit()
                }
            }
            HStack {
                statusText
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if catalog.status == .updating {
                    ProgressView().controlSize(.small)
                }
                Button("Buscar novedades") {
                    Task { await catalog.update() }
                }
                .disabled(catalog.status == .updating)
            }
            Toggle("Buscar novedades al abrir la app", isOn: $autoUpdate)
        } header: {
            Text("Catálogo")
        } footer: {
            Text("El catálogo viene incluido en la app para buscar al instante y sin conexión. Al buscar novedades solo se descargan los títulos añadidos a lamovie desde la última vez. La búsqueda automática se hace como mucho una vez al día y suele gastar menos de 100 KB.")
        }
        .task { await catalog.load() }
    }

    @ViewBuilder
    private var statusText: some View {
        switch catalog.status {
        case .updating:
            Text("Buscando novedades…")
        case .done(let added):
            Text(added == 0 ? "Ya está al día" : "\(added) \(added == 1 ? "título nuevo" : "títulos nuevos")")
        case .failed:
            Text("No se pudo conectar con lamovie")
        case .idle:
            if let checked = catalog.lastCheckedAt {
                Text("Comprobado \(checked.formatted(.relative(presentation: .named)))")
            } else {
                Text("Aún no se han buscado novedades")
            }
        }
    }
}
