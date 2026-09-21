import SwiftUI
import CryptoKit
import Translation

struct Shelf: Identifiable {
    let id: String
    let title: String
    let items: [CatalogItem]
}

@MainActor
final class HomeViewModel: ObservableObject {
    enum State { case loading, loaded, failed }

    @Published private(set) var shelves: [Shelf] = []
    @Published private(set) var state = State.loading

    /// Hasta 5 candidatas para el banner grande, que rota entre ellas.
    var featuredItems: [CatalogItem] {
        let items = shelves.first { $0.id == "movies" }?.items ?? []
        return Array(items.filter { $0.images.backdropURL != nil }.prefix(5))
    }

    func load() async {
        if shelves.isEmpty { state = .loading }

        async let movies = fetch("movies", "Películas recién añadidas", .movies)
        async let series = fetch("series", "Series recién añadidas", .tvshows)
        async let animes = fetch("animes", "Animes recién añadidos", .animes)

        // Una fila que falla no debe tumbar el resto de la pantalla.
        let loaded = await [movies, series, animes].compactMap { $0 }
        if loaded.isEmpty {
            if shelves.isEmpty { state = .failed }
        } else {
            shelves = loaded
            state = .loaded
        }
    }

    private func fetch(_ id: String, _ title: String, _ kind: ContentKind, orderBy: String = "latest") async -> Shelf? {
        guard let items = try? await LaMovieAPI.listing(kind, orderBy: orderBy), !items.isEmpty else { return nil }
        return Shelf(id: id, title: title, items: items)
    }
}

/// Carga el catálogo completo de un tipo de contenido, página a página (scroll infinito).
@MainActor
final class CategoryViewModel: ObservableObject {
    enum State { case loading, loadingMore, loaded, failed }

    let kind: ContentKind
    @Published private(set) var items: [CatalogItem] = []
    @Published private(set) var state = State.loading

    private var page = 1
    private var hasMore = true

    init(kind: ContentKind) { self.kind = kind }

    func loadInitial() async {
        guard items.isEmpty else { return }
        await reload()
    }

    func reload() async {
        page = 1
        hasMore = true
        state = .loading
        await fetchPage(replacing: true)
    }

    /// Se llama al mostrar un póster; si es de los últimos, pide la siguiente página.
    func loadMoreIfNeeded(currentItem item: CatalogItem) async {
        guard hasMore, state != .loadingMore, state != .loading else { return }
        guard items.suffix(6).contains(where: { $0.id == item.id }) else { return }
        state = .loadingMore
        await fetchPage(replacing: false)
    }

    private func fetchPage(replacing: Bool) async {
        do {
            let newItems = try await LaMovieAPI.listing(kind, orderBy: "latest", perPage: 30, page: page)
            items = replacing ? newItems : items + newItems
            hasMore = !newItems.isEmpty
            page += 1
            state = .loaded
        } catch {
            state = items.isEmpty ? .failed : .loaded
        }
    }
}

@MainActor
final class SearchViewModel: ObservableObject {
    enum State: Equatable { case idle, tooShort, loading, results([CatalogItem]), empty, failed }

    @Published private(set) var state = State.idle
    /// Títulos de TMDB afines a lo escrito, con sus nombres alternativos.
    @Published private(set) var suggestions: [TitleSuggestion] = []
    /// Nombre alternativo con el que se encontraron resultados cuando el escrito no dio ninguno.
    @Published private(set) var fallbackName: String?

    /// Se llama con cada cambio del texto; la tarea anterior se cancela sola.
    func run(_ raw: String) async {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { state = .idle; suggestions = []; fallbackName = nil; return }
        if query.count < 3 { state = .tooShort; suggestions = []; fallbackName = nil; return }

        state = .loading
        suggestions = []
        fallbackName = nil
        try? await Task.sleep(for: .milliseconds(400))
        if Task.isCancelled { return }

        // TMDB (traducción y sugerencias) va en paralelo y nunca retrasa los resultados:
        // lo escrito se busca de inmediato y lo demás se suma cuando llega.
        async let extras = Self.extras(for: query)
        let raw = await Result { try await LaMovieAPI.search(query) }
        if Task.isCancelled { return }

        if case .success(let hits) = raw, !hits.isEmpty {
            state = .results(hits)
            let (translated, found) = await extras
            if Task.isCancelled { return }
            suggestions = found
            if let translated, translated.lowercased() != query.lowercased(),
               let more = try? await LaMovieAPI.search(translated), !Task.isCancelled {
                var seen = Set(hits.map(\.id))
                let added = more.filter { seen.insert($0.id).inserted }
                if !added.isEmpty { state = .results(hits + added) }
            }
            return
        }

        // Sin resultados con lo escrito: se prueba la traducción y, si hace falta, los otros nombres.
        let (translated, found) = await extras
        if Task.isCancelled { return }
        suggestions = found
        var items: [CatalogItem] = []
        var failed = false
        if case .failure = raw { failed = true }
        if let translated, translated.lowercased() != query.lowercased() {
            if let hits = try? await LaMovieAPI.search(translated) { items = hits; failed = false }
            if Task.isCancelled { return }
        }
        if items.isEmpty {
            var tried = Set([query, translated].compactMap { $0?.lowercased() })
            for name in found.flatMap(\.allNames) where name.count >= 3 && tried.insert(name.lowercased()).inserted {
                if let hits = try? await LaMovieAPI.search(name), !hits.isEmpty {
                    items = hits
                    fallbackName = name
                    failed = false
                    break
                }
                if Task.isCancelled { return }
            }
        }
        if Task.isCancelled { return }
        state = !items.isEmpty ? .results(items) : (failed ? .failed : .empty)
    }

    /// Traducción al inglés de lo escrito y sugerencias de TMDB para ambas variantes.
    private static func extras(for query: String) async -> (String?, [TitleSuggestion]) {
        let translated = await QueryTranslator.shared.english(query)
        let queries = [query] + [translated].compactMap { $0 }
        return (translated, await suggestions(for: queries))
    }

    /// Resultados del catálogo para todas las variantes, sin repetir y con la escrita primero.
    /// Falla solo si fallan todas.
    private static func catalogSearch(_ queries: [String]) async throws -> [CatalogItem] {
        var results: [Result<[CatalogItem], Error>] = []
        await withTaskGroup(of: (Int, Result<[CatalogItem], Error>).self) { group in
            for (index, query) in queries.enumerated() {
                group.addTask { (index, await Result { try await LaMovieAPI.search(query) }) }
            }
            var indexed: [(Int, Result<[CatalogItem], Error>)] = []
            for await entry in group { indexed.append(entry) }
            results = indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }
        if results.allSatisfy({ if case .failure = $0 { true } else { false } }), let first = results.first {
            _ = try first.get()
        }
        var seen = Set<Int>()
        return results.flatMap { (try? $0.get()) ?? [] }.filter { seen.insert($0.id).inserted }
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
        return Array(lists.flatMap { $0 }.filter { seen.insert($0.id * 10 + ($0.kind == .movies ? 1 : 2)).inserted }.prefix(5))
    }
}

/// Persiste las últimas búsquedas del usuario (en disco, vía `UserDefaults`).
@MainActor
final class RecentlyViewedStore: ObservableObject {
    @Published private(set) var items: [CatalogItem]

    private let defaultsKey = "recentlyViewed"
    private let limit = 12

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([CatalogItem].self, from: data) {
            items = decoded
        } else {
            items = []
        }
    }

    /// Se llama cada vez que se abre una ficha: la sube al frente de "vistos recientemente".
    func add(_ item: CatalogItem) {
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
        persist()
    }

    func remove(_ item: CatalogItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

// MARK: - Palette

/// Estética tipo Apple TV: negro profundo, superficies "glass" y acentos monocromáticos.
private enum Brand {
    static let background = Color(red: 34 / 255, green: 34 / 255, blue: 35 / 255)
    static let card = Color(white: 0.12)
}

private struct AppBackground: View {
    var body: some View {
        Brand.background.ignoresSafeArea()
    }
}

#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

/// Tipo de imagen en la caché: cada uno vive en su propia subcarpeta, para poder ver
/// cuánto ocupa y borrarlo por separado.
enum ImageCategory: String, CaseIterable, Identifiable {
    case poster, backdrop, logo, platform, cast, episode
    /// Archivos de versiones anteriores, sin clasificar (en la raíz de la caché).
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .poster: "Portadas"
        case .backdrop: "Fondos"
        case .logo: "Logos de título"
        case .platform: "Plataformas"
        case .cast: "Reparto"
        case .episode: "Episodios"
        case .other: "Sin clasificar"
        }
    }

    var icon: String {
        switch self {
        case .poster: "rectangle.portrait"
        case .backdrop: "photo"
        case .logo: "textformat"
        case .platform: "play.tv"
        case .cast: "person.2"
        case .episode: "list.and.film"
        case .other: "questionmark.folder"
        }
    }

    var color: Color {
        switch self {
        case .poster: .blue
        case .backdrop: .purple
        case .logo: .orange
        case .platform: .green
        case .cast: .pink
        case .episode: .teal
        case .other: .gray
        }
    }
}

struct CacheUsage: Equatable {
    var count = 0
    var bytes: Int64 = 0
}

/// Caché de imágenes en dos niveles: memoria (`NSCache`) y disco (carpeta Caches de la app),
/// para que portadas, fondos, logos y fotos no se vuelvan a descargar ni al reabrir la app.
/// Es independiente de las cabeceras HTTP del servidor.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let memory = NSCache<NSURL, PlatformImage>()
    private let root: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Solo la memoria: respuesta inmediata para pintar sin parpadeo.
    func image(for url: URL) -> PlatformImage? { memory.object(forKey: url as NSURL) }
    func insert(_ image: PlatformImage, for url: URL) { memory.setObject(image, forKey: url as NSURL) }

    private nonisolated static func folder(_ category: ImageCategory, in root: URL) -> URL {
        // `.other` es la propia raíz (donde estaban los archivos antiguos).
        category == .other ? root : root.appendingPathComponent(category.rawValue, isDirectory: true)
    }

    private func file(for url: URL, category: ImageCategory) -> URL {
        let folder = Self.folder(category, in: root)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(hash)
    }

    /// Imágenes y bytes en disco, por categoría.
    func usage() async -> [ImageCategory: CacheUsage] {
        let root = root
        return await Task.detached {
            var result: [ImageCategory: CacheUsage] = [:]
            for category in ImageCategory.allCases {
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: Self.folder(category, in: root), includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? []
                var usage = CacheUsage()
                for file in files {
                    let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard values?.isRegularFile == true else { continue }   // salta las subcarpetas
                    usage.count += 1
                    usage.bytes += Int64(values?.fileSize ?? 0)
                }
                result[category] = usage
            }
            return result
        }.value
    }

    /// Borra de disco las imágenes de esas categorías sin usar desde hace más de `age`
    /// segundos, o todas si es `nil`. Devuelve los bytes liberados.
    @discardableResult
    func clear(_ categories: Set<ImageCategory>, olderThan age: TimeInterval?) async -> Int64 {
        memory.removeAllObjects()
        let root = root
        return await Task.detached {
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
            let limit = age.map { Date().addingTimeInterval(-$0) }
            var freed: Int64 = 0
            for category in categories {
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: Self.folder(category, in: root), includingPropertiesForKeys: keys)) ?? []
                for file in files {
                    let values = try? file.resourceValues(forKeys: Set(keys))
                    guard values?.isRegularFile == true else { continue }
                    if let limit, let modified = values?.contentModificationDate, modified >= limit { continue }
                    if (try? FileManager.default.removeItem(at: file)) != nil {
                        freed += Int64(values?.fileSize ?? 0)
                    }
                }
            }
            return freed
        }.value
    }

    /// Memoria → disco → red (y se guarda en disco, en la carpeta de su categoría).
    func load(_ url: URL, category: ImageCategory) async -> PlatformImage? {
        if let cached = image(for: url) { return cached }

        let file = file(for: url, category: category)
        let stored = await Task.detached { () -> Data? in
            guard let data = try? Data(contentsOf: file) else { return nil }
            // Se anota el último uso: "borrar lo antiguo" borra lo que lleva tiempo sin verse.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return data
        }.value
        if let data = stored, let loaded = PlatformImage(data: data) {
            insert(loaded, for: url)
            return loaded
        }

        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let loaded = PlatformImage(data: data) else { return nil }
        insert(loaded, for: url)
        Task.detached { try? data.write(to: file, options: .atomic) }
        return loaded
    }
}

/// Como `AsyncImage`, pero pasando por `ImageCache` (memoria + disco).
struct CachedAsyncImage<Content: View>: View {
    let url: URL?
    let category: ImageCategory
    @ViewBuilder let content: (AsyncImagePhase) -> Content
    @State private var phase: AsyncImagePhase = .empty

    init(url: URL?, category: ImageCategory, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.category = category
        self.content = content
        // Si ya está en memoria se pinta en el primer fotograma, sin parpadeo.
        if let url, let cached = MainActor.assumeIsolated({ ImageCache.shared.image(for: url) }) {
            _phase = State(initialValue: .success(Self.swiftUIImage(cached)))
        }
    }

    var body: some View {
        content(phase)
            .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { phase = .empty; return }
        if let loaded = await ImageCache.shared.load(url, category: category) {
            phase = .success(Self.swiftUIImage(loaded))
        } else if !Task.isCancelled {
            phase = .failure(URLError(.cannotLoadFromNetwork))
        }
    }

    private static func swiftUIImage(_ image: PlatformImage) -> Image {
        #if os(macOS)
        Image(nsImage: image)
        #else
        Image(uiImage: image)
        #endif
    }
}

extension CachedAsyncImage {
    /// Misma forma que `AsyncImage(url:) { image in … } placeholder: { … }`.
    init<I: View, P: View>(url: URL?, category: ImageCategory, @ViewBuilder content: @escaping (Image) -> I, @ViewBuilder placeholder: @escaping () -> P)
    where Content == _ConditionalContent<I, P> {
        self.init(url: url, category: category) { phase in
            if let image = phase.image { content(image) } else { placeholder() }
        }
    }
}

struct PosterImage: View {
    let url: URL?
    var category: ImageCategory = .poster
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                #if os(macOS)
                Image(nsImage: image).resizable()
                #else
                Image(uiImage: image).resizable()
                #endif
            } else {
                Brand.card
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { image = nil; return }
        if let cached = ImageCache.shared.image(for: url) {
            image = cached
            return
        }
        if let loaded = await ImageCache.shared.load(url, category: category) { image = loaded }
    }
}

/// Descarga una imagen a la caché en memoria (sin mostrarla) para que aparezca al instante.
@MainActor
private func prefetchImage(_ url: URL?, category: ImageCategory) async {
    guard let url else { return }
    _ = await ImageCache.shared.load(url, category: category)
}

/// Ruta de navegación compartida: permite que `PosterCard` empuje la ficha en el mismo
/// `NavigationStack` que usa "Más información" del hero.
@MainActor
final class NavigationRouter: ObservableObject {
    @Published var path = NavigationPath()
}

/// Dimensiones de la ficha de detalle.
enum DetailCard {
    static let cornerRadius: CGFloat = 0
    static let topMargin: CGFloat = 0
    static let horizontalMargin: CGFloat = 0
    static let contentHorizontalPadding: CGFloat = 48
}

struct HomeView: View {
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @StateObject private var search = SearchViewModel()
    @StateObject private var recentlyViewed = RecentlyViewedStore()
    @ObservedObject private var watchProgress = WatchProgressStore.shared
    @ObservedObject private var translator = QueryTranslator.shared
    @State private var query = ""
    @State private var selection: SidebarCategory? = .home
    @State private var showingSettings = false
    @StateObject private var router = NavigationRouter()

    @StateObject private var model = HomeViewModel()
    @StateObject private var moviesModel = CategoryViewModel(kind: .movies)
    @StateObject private var seriesModel = CategoryViewModel(kind: .tvshows)
    @StateObject private var animesModel = CategoryViewModel(kind: .animes)

    var body: some View {
        ZStack {
            NavigationSplitView {
                sidebar
            } detail: {
                NavigationStack(path: $router.path) {
                    ZStack(alignment: .topTrailing) {
                        AppBackground()

                        catalog
                    }
                    .navigationDestination(for: CatalogItem.self) { DetailView(item: $0) }
                    .navigationDestination(for: PlaybackTarget.self) { PlayerLoaderView(target: $0) }
                    .hidingNavigationBar()
                    .ignoresSafeArea(edges: .top)
                }
            }
            .navigationSplitViewStyle(.balanced)
            #if os(macOS)
            // En pantalla completa la barra de herramientas dejaba una franja gris arriba.
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .scrollEdgeEffectHidden(true, for: .top)
            #endif
        }
        .environmentObject(router)
        .environmentObject(recentlyViewed)
        .preferredColorScheme(.dark)
        .task { await model.load() }
        .task(id: query) { await search.run(query) }
        // Si falta el idioma de traducción, el sistema pide permiso para descargarlo.
        .translationTask(translator.downloadConfig) { session in
            try? await session.prepareTranslation()
            translator.downloadConfig = nil
        }
        // Cambiar de categoría siempre vuelve a la raíz de esa sección; salir de
        // Buscar limpia el término para no dejarlo pendiente al volver.
        .onChange(of: selection) {
            router.path = NavigationPath()
            if selection != .search { query = "" }
        }
        #if os(iOS)
        .fullScreenCover(item: $coordinator.target) { PlayerCover(target: $0) }
        #endif
    }

    /// Sidebar de categorías: material vibrante nativo, como los de macOS, con el
    /// buscador integrado arriba en vez de flotando sobre el contenido.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("LaMovie")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.top, sidebarTopInset)

            VStack(alignment: .leading, spacing: 8) {
                Text("CATEGORÍAS")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 14)

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SidebarCategory.allCases) { category in
                        SidebarRow(category: category, isSelected: activeCategory == category) {
                            selection = category
                        }
                    }
                }
            }

            Spacer()

            Button { showingSettings = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 20)
                    Text("Ajustes")
                        .font(.system(size: 13.5))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 280)
        .sheet(isPresented: $showingSettings) { SettingsView() }
    }

    private var sidebarTopInset: CGFloat {
        #if os(macOS)
        36
        #else
        16
        #endif
    }


    /// Solo la portada de Inicio depende de `HomeViewModel`; el resto de categorías
    /// muestran su propio catálogo completo paginado vía `CategoryViewModel`.
    private var catalog: some View {
        Group {
            if activeCategory == .home {
                switch model.state {
                case .loading where model.shelves.isEmpty:
                    ProgressView("Cargando catálogo…")
                        .tint(.white)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed:
                    VStack(spacing: 14) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.7))
                        Text("No se pudo cargar el catálogo")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Button("Reintentar") { Task { await model.load() } }
                            .buttonStyle(.glass)
                            .pointerCursor()
                            .tint(.white)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                default:
                    homeContent
                }
            } else if activeCategory == .search {
                SearchLandingView(
                    query: $query,
                    searchState: search.state,
                    suggestions: search.suggestions,
                    fallbackName: search.fallbackName,
                    recentlyViewed: recentlyViewed,
                    onSelectCategory: { selection = $0 }
                )
            } else if let categoryModel = categoryModel(for: activeCategory) {
                CategoryGridView(model: categoryModel)
            }
        }
    }

    private var activeCategory: SidebarCategory { selection ?? .home }

    private func categoryModel(for category: SidebarCategory) -> CategoryViewModel? {
        switch category {
        case .home, .search: nil
        case .movies: moviesModel
        case .series: seriesModel
        case .animes: animesModel
        }
    }

    private var homeContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 44) {
                if !model.featuredItems.isEmpty {
                    HeroCarousel(items: model.featuredItems)
                        .ignoresSafeArea(edges: .top)
                }
                if !watchProgress.entries.isEmpty {
                    ContinueWatchingShelf(store: watchProgress)
                }
                ForEach(model.shelves) { shelf in
                    ShelfView(shelf: shelf)
                }
            }
            .padding(.top, model.featuredItems.isEmpty ? 24 : 0)
            .padding(.bottom, 56)
        }
        .coordinateSpace(name: HeroScroll.space)
        .refreshable { await model.load() }
    }
}

/// Espacio de coordenadas del scroll del inicio, para el parallax del hero.
private enum HeroScroll { static let space = "homeScroll" }

/// Grid con scroll infinito para el catálogo completo de una categoría.
private struct CategoryGridView: View {
    @ObservedObject var model: CategoryViewModel

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                ForEach(model.items) { item in
                    PosterCard(item: item)
                        .task { await model.loadMoreIfNeeded(currentItem: item) }
                }
            }
            .padding(36)

            if model.state == .loadingMore {
                ProgressView().tint(.white).padding(.vertical, 24)
            }
        }
        .overlay {
            if model.state == .loading && model.items.isEmpty {
                ProgressView("Cargando catálogo…")
                    .tint(.white)
                    .foregroundStyle(.white)
            } else if model.state == .failed && model.items.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("No se pudo cargar el catálogo")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Button("Reintentar") { Task { await model.reload() } }
                        .buttonStyle(.glass)
                        .pointerCursor()
                        .tint(.white)
                }
            }
        }
        .task { await model.loadInitial() }
        .refreshable { await model.reload() }
    }
}

/// Categorías del sidebar; no alteran cómo se piden los datos, solo qué estantes se muestran.
private enum SidebarCategory: String, CaseIterable, Identifiable, Hashable {
    case home, search, movies, series, animes

    var id: String { rawValue }

    /// Las que se pueden explorar como catálogo (sin Inicio ni Buscar), usadas
    /// como accesos rápidos dentro de la propia vista de búsqueda.
    static var browsable: [SidebarCategory] { [.movies, .series, .animes] }

    var title: String {
        switch self {
        case .home: "Inicio"
        case .search: "Buscar"
        case .movies: "Películas"
        case .series: "Series"
        case .animes: "Animes"
        }
    }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .search: "magnifyingglass"
        case .movies: "film"
        case .series: "tv"
        case .animes: "sparkles.tv"
        }
    }
}

/// Fila del sidebar con foco tipo tvOS: escala y cristal al seleccionar/pasar el cursor.
private struct SidebarRow: View {
    let category: SidebarCategory
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: category.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 20)
                Text(category.title)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? .white : .white.opacity(hovering ? 0.85 : 0.6))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                Color.clear
                    .glassEffect(.regular.tint(.white.opacity(0.35)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if hovering {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(0.06))
            }
        }
        .padding(.horizontal, 10)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .onHover { hovering = $0 }
    }
}

private extension View {
    @ViewBuilder
    func hidingNavigationBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .navigationBar)
        #else
        // En macOS la ventana ya usa .hiddenTitleBar (ver VimeoPlayerApp): sin barra
        // gris, pero conservando los botones de cerrar/minimizar/maximizar flotando.
        self
        #endif
    }
}

// MARK: - Search

/// Pantalla de "Buscar": campo de texto propio, y mientras no se escribe nada,
/// búsquedas recientes y accesos directos a las categorías (como Apple TV).
private struct SearchLandingView: View {
    @Binding var query: String
    let searchState: SearchViewModel.State
    let suggestions: [TitleSuggestion]
    let fallbackName: String?
    @ObservedObject var recentlyViewed: RecentlyViewedStore
    let onSelectCategory: (SidebarCategory) -> Void

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if isSearching {
                SearchResultsView(
                    state: searchState,
                    suggestions: suggestions,
                    fallbackName: fallbackName,
                    onPick: { query = $0 }
                )
            } else {
                landing
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.6))
            TextField("Buscar películas, series y animes", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .foregroundStyle(.white)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: 560)
        .padding(.horizontal, 36)
        .padding(.top, 28)
        .padding(.bottom, 24)
    }

    private var landing: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                if !recentlyViewed.items.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Vistos recientemente")
                                .font(.system(.title3, design: .rounded).weight(.semibold))
                                .foregroundStyle(.white)
                            Spacer()
                            Button("Borrar") { recentlyViewed.clear() }
                                .buttonStyle(.plain)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(recentlyViewed.items) { item in
                                    PosterCard(item: item)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("Categorías")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 14) {
                        ForEach(SidebarCategory.browsable) { category in
                            CategoryTile(category: category) {
                                onSelectCategory(category)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension View {
    /// Cursor de manita al pasar el mouse por encima (macOS / iPad con puntero).
    @ViewBuilder
    func pointerCursor() -> some View {
        #if os(macOS)
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        #else
        self
        #endif
    }
}

/// Tarjeta de gradiente vivo, como las categorías de la pestaña Buscar de Apple TV.
private struct CategoryTile: View {
    let category: SidebarCategory
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: category.gradientColors,
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Image(systemName: category.icon)
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.18))
                    .rotationEffect(.degrees(-12))
                    .offset(x: 34, y: -8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .clipped()
                Text(category.title)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                    .padding(14)
            }
            .frame(height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(hovering ? 0.5 : 0.12), lineWidth: hovering ? 1.5 : 1)
            )
            .shadow(color: .black.opacity(hovering ? 0.4 : 0.2), radius: hovering ? 16 : 6, y: hovering ? 8 : 3)
            .scaleEffect(hovering ? 1.03 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: hovering)
        .onHover { hovering = $0 }
        .pointerCursor()
    }
}

private extension SidebarCategory {
    /// Un gradiente distinto por categoría, como en la app de Apple TV.
    var gradientColors: [Color] {
        switch self {
        case .home, .search:
            [Color(red: 0.3, green: 0.3, blue: 0.34), Color(red: 0.14, green: 0.14, blue: 0.17)]
        case .movies:
            [Color(red: 0.16, green: 0.38, blue: 0.92), Color(red: 0.05, green: 0.13, blue: 0.45)]
        case .series:
            [Color(red: 0.95, green: 0.36, blue: 0.16), Color(red: 0.5, green: 0.1, blue: 0.05)]
        case .animes:
            [Color(red: 0.1, green: 0.65, blue: 0.55), Color(red: 0.03, green: 0.28, blue: 0.28)]
        }
    }
}

// MARK: - Trailer y plataformas

/// "Dónde ver": plataformas por país (datos de JustWatch vía TMDB), con selector de país.
/// Tocar una plataforma (o elegirla en "Buscar plataforma") muestra en qué países está el título.
private struct StreamingSection: View {
    let streaming: [String: StreamingAvailability]
    @Binding var country: String
    @State private var selectedProvider: StreamingProvider?

    private static let spanish = Locale(identifier: "es")

    private func name(_ code: String) -> String {
        Self.spanish.localizedString(forRegionCode: code) ?? code
    }

    private var countries: [String] {
        streaming.keys.sorted { name($0).localizedCompare(name($1)) == .orderedAscending }
    }

    /// El país elegido si tiene datos; si no, el primero disponible.
    private var effectiveCountry: String {
        streaming[country] != nil ? country : (countries.first ?? country)
    }

    /// Todas las plataformas del título en cualquier país, sin repetir.
    private var allProviders: [StreamingProvider] {
        var seen = Set<Int>()
        return streaming.values
            .flatMap { $0.subscription + $0.free }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        let availability = streaming[effectiveCountry]
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Dónde ver")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                platformPicker
                countryPicker
            }

            if let availability {
                group("Suscripción", availability.subscription)
                group("Gratis", availability.free)
            }

            if let selectedProvider {
                countriesPanel(for: selectedProvider)
            }

            HStack(spacing: 4) {
                Text("Datos de streaming de JustWatch")
                if let link = availability?.link {
                    Link("· Ver en JustWatch", destination: link)
                }
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.top, 6)
    }

    private var countryPicker: some View {
        SearchablePicker(
            title: name(effectiveCountry),
            systemImage: "globe",
            prompt: "Buscar país",
            options: countries.map { PickerOption(id: $0, title: name($0)) },
            selectedID: effectiveCountry,
            onPick: { country = $0 }
        )
    }

    /// La búsqueda a la inversa: elegir una plataforma y ver en qué países está el título.
    private var platformPicker: some View {
        SearchablePicker(
            title: "Buscar plataforma",
            systemImage: "magnifyingglass",
            prompt: "Buscar plataforma",
            options: allProviders.map { PickerOption(id: String($0.id), title: $0.name, logoURL: $0.logoURL) },
            selectedID: selectedProvider.map { String($0.id) },
            onPick: { id in selectedProvider = allProviders.first { String($0.id) == id } }
        )
    }

    /// Países donde el título está en la plataforma elegida, con el tipo de acceso.
    private func countriesPanel(for provider: StreamingProvider) -> some View {
        let hits: [(code: String, kinds: [String])] = countries.compactMap { code in
            guard let entry = streaming[code] else { return nil }
            var kinds: [String] = []
            if entry.subscription.contains(where: { $0.id == provider.id }) { kinds.append("Suscripción") }
            if entry.free.contains(where: { $0.id == provider.id }) { kinds.append("Gratis") }
            return kinds.isEmpty ? nil : (code, kinds)
        }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                CachedAsyncImage(url: provider.logoURL, category: .platform) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.08)
                }
                .frame(width: 30, height: 30)
                .clipShape(Circle())
                Text(hits.isEmpty
                     ? "No está en \(provider.name) en ningún país"
                     : "En \(provider.name) en \(hits.count) \(hits.count == 1 ? "país" : "países")")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    selectedProvider = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            WrappingChips(spacing: 8) {
                ForEach(hits, id: \.code) { hit in
                    Button {
                        country = hit.code
                    } label: {
                        HStack(spacing: 6) {
                            Text(name(hit.code)).fontWeight(.medium)
                            Text(hit.kinds.joined(separator: " · "))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(.white.opacity(hit.code == effectiveCountry ? 0.2 : 0.09), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 1))
    }

    @ViewBuilder
    private func group(_ title: String, _ providers: [StreamingProvider]) -> some View {
        if !providers.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 22) {
                        ForEach(providers) { provider in
                            ProviderTile(provider: provider, isSelected: provider == selectedProvider) {
                                selectedProvider = provider == selectedProvider ? nil : provider
                            }
                        }
                    }
                    // Aire para el brillo y el zoom del hover: el ScrollView recorta lo que sale.
                    .padding(.horizontal, 36)
                    .padding(.vertical, 40)
                }
                .scrollClipDisabled()
                .padding(.horizontal, -36)
                .padding(.vertical, -14)
            }
        }
    }
}

struct PickerOption: Identifiable, Hashable {
    let id: String
    let title: String
    var logoURL: URL?
}

/// Botón que abre un popover nativo con un campo de búsqueda y la lista filtrada
/// (sin tildes ni mayúsculas). Intro elige la primera coincidencia.
private struct SearchablePicker: View {
    let title: String
    let systemImage: String
    let prompt: String
    let options: [PickerOption]
    let selectedID: String?
    let onPick: (String) -> Void

    @State private var isOpen = false
    @State private var text = ""
    @FocusState private var focused: Bool

    private var filtered: [PickerOption] {
        let query = text.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? options : options.filter { $0.title.localizedStandardContains(query) }
    }

    var body: some View {
        Button { isOpen = true } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .pointerCursor()
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(prompt, text: $text)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit { if let first = filtered.first { pick(first) } }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filtered) { option in
                            Button { pick(option) } label: {
                                HStack(spacing: 10) {
                                    if option.logoURL != nil {
                                        CachedAsyncImage(url: option.logoURL, category: .platform) { image in
                                            image.resizable().scaledToFill()
                                        } placeholder: {
                                            Color.white.opacity(0.08)
                                        }
                                        .frame(width: 26, height: 26)
                                        .clipShape(Circle())
                                    }
                                    Text(option.title).lineLimit(1)
                                    Spacer(minLength: 0)
                                    if option.id == selectedID {
                                        Image(systemName: "checkmark").foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if filtered.isEmpty {
                            Text("Sin resultados")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 20)
                        }
                    }
                }
                .frame(height: 260)
            }
            .padding(12)
            .frame(width: 290)
            .onAppear { text = ""; focused = true }
        }
    }

    private func pick(_ option: PickerOption) {
        onPick(option.id)
        isOpen = false
    }
}

/// Tarjeta circular de plataforma, con el diseño de las competiciones de KerterApp: círculo
/// oscuro con borde, brillo al pasar el ratón y zoom. El logo (que trae su propio fondo)
/// rellena todo el círculo.
private struct ProviderTile: View {
    let provider: StreamingProvider
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false
    @State private var brand: Color?

    private let size: CGFloat = 120
    private var active: Bool { hovering || isSelected }
    private var accent: Color { brand ?? .white }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                CachedAsyncImage(url: provider.logoURL, category: .platform) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color(red: 0.082, green: 0.094, blue: 0.122)
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(
                    Circle().strokeBorder(active ? accent.opacity(0.95) : .white.opacity(0.08),
                                          lineWidth: active ? 2 : 1)
                )
                .shadow(color: active ? accent.opacity(0.45) : .black.opacity(0.5),
                        radius: active ? 18 : 10, y: active ? 4 : 6)
                .scaleEffect(hovering ? 1.05 : 1)

                Text(provider.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.6))
                    .lineLimit(1)
            }
            .frame(width: size + 16)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        .onHover { hovering = $0 }
        .help(provider.name)
        .task(id: provider.logoURL) { brand = await BrandColor.color(for: provider.logoURL) }
    }
}

/// Color de marca de una plataforma, sacado del color más presente y saturado de su logo.
@MainActor
private enum BrandColor {
    private static var cache: [URL: Color] = [:]

    static func color(for url: URL?) async -> Color? {
        guard let url else { return nil }
        if let hit = cache[url] { return hit }
        var loaded = ImageCache.shared.image(for: url)
        if loaded == nil { loaded = await ImageCache.shared.load(url, category: .platform) }
        guard let image = loaded, let color = dominant(of: image) else { return nil }
        cache[url] = color
        return color
    }

    private static func dominant(of image: PlatformImage) -> Color? {
        #if os(macOS)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #else
        guard let cg = image.cgImage else { return nil }
        #endif
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drew else { return nil }

        var r = 0.0, g = 0.0, b = 0.0, total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            guard a > 0.5 else { continue }
            let pr = Double(pixels[i]) / 255 / a, pg = Double(pixels[i + 1]) / 255 / a, pb = Double(pixels[i + 2]) / 255 / a
            let maxC = max(pr, pg, pb), minC = min(pr, pg, pb)
            let saturation = maxC == 0 ? 0 : (maxC - minC) / maxC
            // Se ignoran el blanco, el negro y los grises: no son "el color" de la marca.
            guard saturation > 0.25, maxC > 0.25 else { continue }
            let weight = saturation * saturation
            r += pr * weight; g += pg * weight; b += pb * weight; total += weight
        }
        guard total > 0 else { return nil }
        let base = (r / total, g / total, b / total)
        // Se sube el brillo para que el borde y el resplandor se vean sobre fondo oscuro.
        let peak = max(base.0, base.1, base.2)
        let boost = peak > 0 ? min(1 / peak, 1.6) : 1
        return Color(red: min(base.0 * boost, 1), green: min(base.1 * boost, 1), blue: min(base.2 * boost, 1))
    }
}

// MARK: - Search results

private struct SearchResultsView: View {
    let state: SearchViewModel.State
    let suggestions: [TitleSuggestion]
    let fallbackName: String?
    let onPick: (String) -> Void

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .tooShort:
            message("Escribe al menos 3 caracteres", systemImage: "text.cursor")
        case .empty:
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    message("No se encontraron resultados", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity, minHeight: suggestions.isEmpty ? 260 : 120)
                    if !suggestions.isEmpty {
                        NameSuggestionsView(
                            title: "Prueba con otro nombre",
                            suggestions: suggestions,
                            onPick: onPick
                        )
                    }
                }
                .padding(36)
            }
        case .failed:
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    message("No se pudo completar la búsqueda", systemImage: "wifi.exclamationmark")
                        .frame(maxWidth: .infinity, minHeight: suggestions.isEmpty ? 260 : 120)
                    if !suggestions.isEmpty {
                        NameSuggestionsView(
                            title: "Prueba con otro nombre",
                            suggestions: suggestions,
                            onPick: onPick
                        )
                    }
                }
                .padding(36)
            }
        case .results(let items):
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let fallbackName {
                        FallbackBanner(name: fallbackName)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                        ForEach(items) { item in
                            PosterCard(item: item)
                        }
                    }
                    if !suggestions.isEmpty {
                        SuggestionsDisclosure(suggestions: suggestions, onPick: onPick)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(36)
            }
        }
    }

    private func message(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.largeTitle)
            Text(text).font(.headline)
        }
        .foregroundStyle(.white.opacity(0.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Aviso de que los resultados salieron de otro nombre del mismo título.
private struct FallbackBanner: View {
    let name: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.yellow)
            Text("Mostrando resultados para ")
                .foregroundStyle(.white.opacity(0.7))
            + Text("“\(name)”")
                .fontWeight(.semibold)
                .foregroundStyle(.white)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
    }
}

/// Botón opcional bajo los resultados: al abrirlo muestra las sugerencias de TMDB.
private struct SuggestionsDisclosure: View {
    let suggestions: [TitleSuggestion]
    let onPick: (String) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkle.magnifyingglass")
                    Text(expanded ? "Ocultar sugerencias" : "¿No es lo que buscabas?")
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Capsule())
            .pointerCursor()

            if expanded {
                NameSuggestionsView(title: "También conocida como", suggestions: suggestions, onPick: onPick)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: suggestions)
    }
}

/// Títulos de TMDB afines a lo buscado, cada uno con sus nombres alternativos como
/// botones: al tocar uno se relanza la búsqueda con ese nombre.
private struct NameSuggestionsView: View {
    let title: String
    let suggestions: [TitleSuggestion]
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: "text.magnifyingglass")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(suggestions) { suggestion in
                        SuggestionCard(suggestion: suggestion, onPick: onPick)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

private struct SuggestionCard: View {
    let suggestion: TitleSuggestion
    let onPick: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            poster
            VStack(alignment: .leading, spacing: 8) {
                Button { onPick(suggestion.title) } label: {
                    Text(suggestion.title)
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
                .buttonStyle(.plain)

                HStack(spacing: 6) {
                    Text(suggestion.kind.label)
                    if let year = suggestion.year { Text("· \(year)") }
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))

                if !suggestion.aliases.isEmpty {
                    WrappingChips(spacing: 6) {
                        ForEach(suggestion.aliases, id: \.self) { name in
                            AliasChip(name: name) { onPick(name) }
                        }
                    }
                }
            }
            .frame(width: 210, alignment: .leading)
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.1), lineWidth: 1)
        )
    }

    private var poster: some View {
        CachedAsyncImage(url: suggestion.posterURL, category: .poster) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "film").foregroundStyle(.white.opacity(0.3))
                }
            }
        }
        .frame(width: 66, height: 99)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct AliasChip: View {
    let name: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.85))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.white.opacity(hovering ? 0.22 : 0.1), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(hovering ? 0.4 : 0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
    }
}

/// Coloca sus hijos en filas, saltando de línea cuando no caben.
private struct WrappingChips: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(width: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, layout.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

// MARK: - Hero

/// Banner de destacadas. Cambia con un fundido a oscuro (sale una, entra la otra) y el
/// texto entra con un ligero desplazamiento. Avanza solo cada 7 s y también con dos
/// dedos en el trackpad (o arrastrando); el temporizador se reinicia al cambiar a mano.
private struct HeroCarousel: View {
    let items: [CatalogItem]
    @State private var index = 0
    /// Cuántas páginas (contando desde 0) ya pueden descargar sus datos: las tres primeras
    /// en paralelo al abrir; crece de a dos por delante a medida que el usuario avanza.
    @State private var loadedThrough = 2
    @State private var lastChange = Date.distantPast

    var body: some View {
        ZStack(alignment: .bottom) {
            Brand.background

            ForEach(Array(items.enumerated()), id: \.element.id) { position, item in
                HeroView(item: item, shouldLoad: position <= loadedThrough, isActive: position == index)
                    .allowsHitTesting(position == index)
            }

            if items.count > 1 {
                HStack(spacing: 6) {
                    ForEach(items.indices, id: \.self) { position in
                        Capsule()
                            .fill(.white.opacity(position == index ? 0.9 : 0.35))
                            .frame(width: position == index ? 18 : 6, height: 6)
                    }
                }
                .animation(.easeOut(duration: 0.3), value: index)
                .padding(.bottom, 20)
                .allowsHitTesting(false)
            }
        }
        .background(HorizontalSwipeCatcher { step($0) })
        .simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { value in
                if abs(value.translation.width) > abs(value.translation.height) * 1.5 {
                    step(value.translation.width < 0 ? 1 : -1)
                }
            }
        )
        .onChange(of: index) { _, new in loadedThrough = max(loadedThrough, new + 2) }
        .task(id: TimerKey(ids: items.map(\.id), index: index)) { await autoAdvance() }
    }

    private struct TimerKey: Hashable { let ids: [Int]; let index: Int }

    /// Cambia de página (`1` siguiente, `-1` anterior), ignorando gestos mientras dura el fundido.
    private func step(_ direction: Int) {
        guard items.count > 1, Date().timeIntervalSince(lastChange) > 0.9 else { return }
        lastChange = Date()
        index = (index + direction + items.count) % items.count
    }

    private func autoAdvance() async {
        guard items.count > 1 else { return }
        try? await Task.sleep(for: .seconds(7))
        if Task.isCancelled { return }
        lastChange = Date()
        index = (index + 1) % items.count
    }
}

#if os(macOS)
/// Detecta el deslizamiento horizontal con dos dedos sobre su área (rueda/trackpad).
private struct HorizontalSwipeCatcher: NSViewRepresentable {
    let onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> NSView { CatcherView(onSwipe: onSwipe) }
    func updateNSView(_ view: NSView, context: Context) { (view as? CatcherView)?.onSwipe = onSwipe }

    private final class CatcherView: NSView {
        var onSwipe: (Int) -> Void
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var fired = false

        init(onSwipe: @escaping (Int) -> Void) {
            self.onSwipe = onSwipe
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window else { return event }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return event }
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || accumulated != 0 else { return event }

            if event.phase == .began { accumulated = 0; fired = false }
            accumulated += event.scrollingDeltaX
            if !fired, abs(accumulated) > 50 {
                fired = true
                onSwipe(accumulated < 0 ? 1 : -1)
            }
            if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended {
                accumulated = 0
                fired = false
            }
            return nil
        }
    }
}
#else
private struct HorizontalSwipeCatcher: View {
    let onSwipe: (Int) -> Void
    var body: some View { Color.clear }
}
#endif

private struct HeroView: View {
    let item: CatalogItem
    let shouldLoad: Bool
    var isActive = true
    @State private var tmdbBackdropURL: URL?
    @State private var qualityTiers: [QualityTier] = []
    @State private var hasWebDL = false

    #if os(iOS)
    private let centered = true
    private let heroHeight: CGFloat = 650
    #else
    private let centered = false
    #endif

    var body: some View {
        ZStack(alignment: centered ? .bottom : .bottomLeading) {
            Group {
            // Parallax: al subir, la imagen se queda atrás (va a la mitad de velocidad);
            // al tirar hacia abajo, se estira.
            GeometryReader { proxy in
                let minY = proxy.frame(in: .named(HeroScroll.space)).minY
                let height = proxy.size.height
                let pull = max(0, minY)
                // Sin margen extra: la imagen baja dentro del hero al hacer scroll, y el hueco que
                // deja arriba queda siempre fuera de la pantalla (el hero ya subió más que eso).
                let shift = max(0, -minY) * 0.5
                Color(white: 0.05)
                    .overlay {
                        PosterImage(url: tmdbBackdropURL, category: .backdrop)
                            .aspectRatio(contentMode: .fill)
                    }
                    .frame(width: proxy.size.width, height: height + pull)
                    .offset(y: shift - pull)
            }
            .clipped()

            LinearGradient(
                colors: centered
                    ? [Brand.background.opacity(0.35), .clear, Brand.background.opacity(0.65), Brand.background]
                    : [.clear, .clear, Brand.background.opacity(0.5), Brand.background],
                startPoint: .top, endPoint: .bottom
            )
            if !centered {
                LinearGradient(
                    colors: [Brand.background.opacity(0.75), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
            }
            }
            // Fundido a oscuro: la saliente se apaga primero y la entrante aparece después.
            .opacity(isActive ? 1 : 0)
            .animation(isActive ? .easeInOut(duration: 0.6).delay(0.3) : .easeInOut(duration: 0.4), value: isActive)

            VStack(alignment: centered ? .center : .leading, spacing: 14) {
                TitleLogo(item: item, textFont: .system(size: centered ? 34 : 42, weight: .bold, design: .rounded),
                          enabled: shouldLoad, alignment: centered ? .center : .leading)

                DetailMetaRow(item: item, tiers: qualityTiers, hasWebDL: hasWebDL, fontSize: centered ? 14 : 17)

                if !item.overview.isEmpty {
                    Text(item.overview)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(centered ? 3 : 2)
                        .multilineTextAlignment(centered ? .center : .leading)
                        .frame(maxWidth: 520, alignment: centered ? .center : .leading)
                }

                HStack(spacing: 14) {
                    PlayButton(target: PlaybackTarget(postId: item.id, title: item.displayTitle, watch: WatchInfo(item: item))) {
                        Label("Reproducir", systemImage: "play.fill")
                            .font(.headline)
                            .padding(.horizontal, centered ? 22 : 26)
                            .padding(.vertical, 12)
                            .foregroundStyle(.black)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(.white).interactive(), in: Capsule())
                    .pointerCursor()

                    NavigationLink(value: item) {
                        Label(centered ? "Más info" : "Más información", systemImage: "info.circle")
                            .font(.headline)
                            .padding(.horizontal, centered ? 18 : 22)
                            .padding(.vertical, 12)
                            .foregroundStyle(.white)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .pointerCursor()
                }
                .padding(.top, 4)
            }
            .padding(EdgeInsets(top: 20, leading: centered ? 20 : 36, bottom: centered ? 48 : 40, trailing: centered ? 20 : 36))
            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
            // El texto entra un poco después que la imagen, subiendo suavemente.
            .opacity(isActive ? 1 : 0)
            .offset(y: isActive ? 0 : 14)
            .animation(isActive ? .easeOut(duration: 0.6).delay(0.5) : .easeIn(duration: 0.3), value: isActive)
        }
        #if os(macOS)
        // Misma relación de aspecto que los fondos de TMDB (16:9): la imagen se ve completa.
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        #else
        .frame(height: heroHeight)
        #endif
        .task(id: shouldLoad) {
            guard shouldLoad, tmdbBackdropURL == nil else { return }
            async let images = TMDBService.shared.images(for: item)
            async let downloads = (try? await LaMovieAPI.downloads(postId: item.id)) ?? []
            let (resolvedImages, resolvedDownloads) = await (images, downloads)
            qualityTiers = resolvedDownloads.qualityTiers
            hasWebDL = resolvedDownloads.contains(where: \.isWebDL)
            #if os(iOS)
            // En móvil el hero es vertical: se usa la portada sin texto (el logo va aparte encima).
            tmdbBackdropURL = resolvedImages.heroPoster ?? resolvedImages.backdrop
            #else
            tmdbBackdropURL = resolvedImages.backdrop
            #endif
        }
    }
}

// MARK: - Rows

private struct ShelfView: View {
    let shelf: Shelf

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(shelf.title)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 36)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(shelf.items) { item in
                        PosterCard(item: item)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 16)
            }
        }
    }
}

private struct PosterCard: View {
    let item: CatalogItem
    @State private var hovering = false
    @State private var tmdbPosterURL: URL?
    @EnvironmentObject private var router: NavigationRouter
    @EnvironmentObject private var recentlyViewed: RecentlyViewedStore

    private var posterURL: URL? { tmdbPosterURL ?? item.images.posterURL }

    var body: some View {
        Button {
            router.path.append(item)
            recentlyViewed.add(item)
        } label: {
            cardBody
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .task(id: item.id) { tmdbPosterURL = await TMDBService.shared.images(for: item).poster }
    }

    private var cardBody: some View {
        Brand.card
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                PosterImage(url: posterURL)
                    .aspectRatio(contentMode: .fill)
                    .clipped()
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(hovering ? 1 : 0), lineWidth: 2)
            )
            .overlay(alignment: .topTrailing) {
                if let rating = item.ratingText {
                    Label(rating, systemImage: "star.fill")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .foregroundStyle(.white)
                        .glassEffect(.regular, in: Capsule())
                        .padding(6)
                }
            }
            .frame(width: 190)
            .animation(.easeInOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Sinopsis de la ficha: encabezado, texto grande con buen interlineado y ancho de lectura cómodo.
private struct SynopsisSection: View {
    let text: String

    private var paragraphs: [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sinopsis")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.system(size: 17, weight: .regular, design: .default))
                        .lineSpacing(6)
                        .foregroundStyle(.white.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 780, alignment: .leading)
            .textSelection(.enabled)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
    }
}

private struct MetaRow: View {
    let item: CatalogItem

    var body: some View {
        HStack(spacing: 8) {
            if let rating = item.ratingText {
                Label(rating, systemImage: "star.fill").foregroundStyle(.white.opacity(0.85))
            }
            Text(([item.kind.label] + [item.metaLine]).filter { !$0.isEmpty }.joined(separator: " · "))
                .foregroundStyle(.white.opacity(0.65))
        }
        .font(.subheadline.weight(.medium))
    }
}

/// Fila de metadatos de la ficha, como en Apple TV: año · duración, clasificación con
/// icono y, a continuación, las insignias de calidad.
private struct DetailMetaRow: View {
    let item: CatalogItem
    let tiers: [QualityTier]
    let hasWebDL: Bool
    var fontSize: CGFloat = 17

    var body: some View {
        HStack(spacing: 10) {
            Text([item.year, item.runtimeText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .foregroundStyle(.white.opacity(0.75))

            if let rating = item.ratingText {
                Label(rating, systemImage: "star.fill")
                    .foregroundStyle(.white.opacity(0.75))
            }

            if let certification = item.certification, !certification.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .fontWeight(.semibold)
                    Text(certification)
                }
                .foregroundStyle(.white.opacity(0.75))
            }

            // Solo la calidad más alta: si hay 4K no se muestra además FULL HD / HD.
            if let top = tiers.first { QualityBadge(label: top.label, filled: true) }
            if hasWebDL { QualityBadge(label: "WEB-DL") }
        }
        .font(.system(size: fontSize, weight: .medium, design: .rounded))
    }
}

// MARK: - Detail

struct DetailView: View {
    let item: CatalogItem
    /// No-nil cuando se muestra como tarjeta flotante sobre el catálogo (en vez de
    /// empujada a pantalla completa); permite cerrarla y deja ver la vista de atrás.
    var onDismiss: (() -> Void)?

    @State private var seasons: [Int] = []
    @State private var season: Int?
    @State private var episodes: [Episode] = []
    @State private var loadingEpisodes = false
    @State private var downloadTarget: PlaybackTarget?
    @State private var seasonRequest: SeasonDownloadRequest?
    @State private var tmdbDetails: TMDBDetails?
    @State private var tmdbBackdropURL: URL?
    @State private var qualityTiers: [QualityTier] = []
    @State private var hasWebDL = false
    @Environment(\.openURL) private var openURL
    @AppStorage("streamingCountry") private var streamingCountry = Locale.current.region?.identifier ?? "US"
    /// La ficha no se muestra hasta tener portada, logo, sinopsis y calidades.
    @State private var ready = false

    private var isSeries: Bool { item.kind != .movies }

    /// Sinopsis: se prefiere la de TMDB (en español) si está disponible.
    private var overviewText: String {
        if let overview = tmdbDetails?.overview, !overview.isEmpty { return overview }
        return item.overview
    }

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                card
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            .opacity(ready ? 1 : 0)

            if !ready {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .pointerCursor()
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .navigationTitle(item.displayTitle)
        .task(id: season) { await loadEpisodes() }
        .task(id: item.id) { await loadEssentials() }
        // Red de seguridad: si algo tarda demasiado, se muestra la ficha con lo que haya.
        .task(id: item.id) {
            try? await Task.sleep(for: .seconds(12))
            ready = true
        }
        .animation(.easeOut(duration: 0.25), value: ready)
        .sheet(item: $downloadTarget) { DownloadSheet(target: $0) }
        .sheet(item: $seasonRequest) { SeasonDownloadSheet(request: $0) }
    }

    /// Todo lo necesario para pintar la cabecera, en paralelo; al terminar se muestra la ficha.
    private func loadEssentials() async {
        async let tmdb: Void = loadTMDBDetails()
        async let quality: Void = loadQuality()
        _ = await (tmdb, quality)
        ready = true
    }

    private func loadTMDBDetails() async {
        async let details = TMDBService.shared.details(for: item)
        async let images = TMDBService.shared.images(for: item)
        let (resolvedDetails, resolvedImages) = await (details, images)
        let backdrop = resolvedImages.backdrop ?? resolvedImages.poster
        // Portada y logo descargados antes de mostrar la ficha.
        async let warmBackdrop: Void = prefetchImage(backdrop, category: .backdrop)
        async let warmLogo: Void = prefetchImage(resolvedImages.logo, category: .logo)
        _ = await (warmBackdrop, warmLogo)
        tmdbDetails = resolvedDetails
        tmdbBackdropURL = backdrop
    }

    /// Solo para películas: los episodios tienen su propia calidad por enlace.
    private func loadQuality() async {
        guard !isSeries else { return }
        let downloads = (try? await LaMovieAPI.downloads(postId: item.id)) ?? []
        qualityTiers = downloads.qualityTiers
        hasWebDL = downloads.contains(where: \.isWebDL)
    }

    /// Ficha a pantalla completa cuya cabecera coincide en tamaño con el destino
    /// de la animación de expansión del póster.
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Color.clear
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)

                LinearGradient(
                    colors: [.clear, .clear, .black.opacity(0.55), .black.opacity(0.92)],
                    startPoint: .top, endPoint: .bottom
                )

                // Título, metadatos y botón de reproducir sobre la portada, como en
                // la cabecera de un servicio de streaming.
                VStack(alignment: .leading, spacing: 16) {
                    TitleLogo(item: item, textFont: .system(size: 40, weight: .bold, design: .rounded))
                        .shadow(color: .black.opacity(0.6), radius: 12, y: 4)
                    DetailMetaRow(item: item, tiers: qualityTiers, hasWebDL: hasWebDL)

                    if !item.genreNames.isEmpty {
                        Text(item.genreNames.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    HStack(spacing: 12) {
                        if !isSeries {
                                PlayButton(target: PlaybackTarget(postId: item.id, title: item.displayTitle, watch: WatchInfo(item: item))) {
                                    Label("Reproducir", systemImage: "play.fill")
                                        .font(.headline)
                                        .padding(.horizontal, 28)
                                        .padding(.vertical, 14)
                                        .foregroundStyle(.black)
                                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .glassEffect(.regular.tint(.white).interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .pointerCursor()

                                Button {
                                    downloadTarget = PlaybackTarget(postId: item.id, title: item.displayTitle)
                                } label: {
                                    Label("Descargar", systemImage: "arrow.down")
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 24)
                                        .padding(.vertical, 14)
                                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .pointerCursor()
                        }

                        if let trailer = tmdbDetails?.trailer {
                            Button {
                                if let url = URL(string: "https://www.youtube.com/watch?v=\(trailer.key)") { openURL(url) }
                            } label: {
                                Label("Tráiler", systemImage: "play.rectangle")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 14)
                                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .pointerCursor()
                        }
                    }

                    if let tagline = [tmdbDetails?.tagline, item.tagline].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
                        Text(tagline)
                            .italic()
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, DetailCard.contentHorizontalPadding)
                .padding(.bottom, 36)
            }
            .background {
                // La imagen llena todo el ancho y alto de la cabecera, aunque el contenido la agrande.
                GeometryReader { proxy in
                    PosterImage(url: tmdbBackdropURL, category: .backdrop)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
                .background(Color(white: 0.05))
            }

            VStack(alignment: .leading, spacing: 18) {
                if !overviewText.isEmpty {
                    SynopsisSection(text: overviewText)
                }

                if let details = tmdbDetails {
                    infoSection(details)
                }

                if let streaming = tmdbDetails?.streaming, !streaming.isEmpty {
                    StreamingSection(streaming: streaming, country: $streamingCountry)
                }

                if let cast = tmdbDetails?.cast, !cast.isEmpty {
                    castSection(cast)
                }

                if isSeries { episodesSection }
            }
            .padding(.horizontal, DetailCard.contentHorizontalPadding)
            .padding(.top, 24)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity)
        .background(Brand.card)
    }

    private func infoRows(_ details: TMDBDetails) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let rating = details.rating {
            var text = String(format: "★ %.1f / 10", rating)
            if let votes = details.voteCount { text += " (\(votes) votos)" }
            rows.append(("Puntuación TMDB", text))
        }
        if let minutes = details.runtimeMinutes, minutes > 0 {
            rows.append(("Duración", isSeries ? "\(minutes) min por episodio" : "\(minutes / 60) h \(minutes % 60) min"))
        }
        if let seasonCount = details.seasonCount {
            var text = "\(seasonCount)"
            if let episodeCount = details.episodeCount { text += " · \(episodeCount) episodios" }
            rows.append(("Temporadas", text))
        }
        if let date = details.releaseDate, !date.isEmpty { rows.append(("Estreno", date)) }
        if !details.directors.isEmpty {
            rows.append((isSeries ? "Creado por" : "Dirección", details.directors.joined(separator: ", ")))
        }
        if !isSeries, !details.writers.isEmpty { rows.append(("Guion", details.writers.joined(separator: ", "))) }
        if !details.genres.isEmpty { rows.append(("Géneros", details.genres.joined(separator: ", "))) }
        if !details.countries.isEmpty { rows.append(("País", details.countries.joined(separator: ", "))) }
        if let language = details.originalLanguage { rows.append(("Idioma original", language.capitalized)) }
        if !details.studios.isEmpty { rows.append(("Estudios", details.studios.joined(separator: ", "))) }
        return rows
    }

    /// Datos extra de TMDB: puntuación, duración, dirección, países, estudios…
    @ViewBuilder
    private func infoSection(_ details: TMDBDetails) -> some View {
        let rows = infoRows(details)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Información")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                ForEach(rows, id: \.0) { label, value in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(label)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 130, alignment: .leading)
                        Text(value)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private func castSection(_ cast: [CastMember]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reparto")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(cast) { member in
                        VStack(spacing: 6) {
                            Circle()
                                .fill(Brand.card)
                                .frame(width: 64, height: 64)
                                .overlay {
                                    CachedAsyncImage(url: member.profileURL, category: .cast) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        Image(systemName: "person.fill")
                                            .foregroundStyle(.white.opacity(0.3))
                                    }
                                }
                                .clipShape(Circle())

                            Text(member.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)

                            if let character = member.character, !character.isEmpty {
                                Text(character)
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.5))
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: 84)
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private var episodesSection: some View {
        HStack {
            Text("Episodios")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)
            Spacer()
            if let season, !episodes.isEmpty {
                Button {
                    seasonRequest = SeasonDownloadRequest(seriesTitle: item.displayTitle, season: season, episodes: episodes)
                } label: {
                    Label("Descargar temporada", systemImage: "arrow.down.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Capsule())
                .pointerCursor()
            }
            if seasons.count > 1 {
                Picker("Temporada", selection: $season) {
                    ForEach(seasons, id: \.self) { Text("Temporada \($0)").tag(Optional($0)) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.top, 14)

        if loadingEpisodes && episodes.isEmpty {
            ProgressView().tint(.white).frame(maxWidth: .infinity)
        }
        ForEach(episodes) { episode in
            let episodeTitle = "\(item.displayTitle) · T\(episode.seasonNumber) E\(episode.episodeNumber)"
            HStack(spacing: 8) {
                PlayButton(target: PlaybackTarget(
                    postId: episode.id, title: episodeTitle,
                    watch: WatchInfo(item: item, season: episode.seasonNumber, episode: episode.episodeNumber, episodeTitle: episode.title)
                )) {
                    EpisodeRow(episode: episode)
                }
                .buttonStyle(.plain)

                Button {
                    downloadTarget = PlaybackTarget(postId: episode.id, title: episodeTitle)
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .pointerCursor()
                .help("Descargar")
            }
        }
    }

    private func loadEpisodes() async {
        guard isSeries else { return }
        loadingEpisodes = true
        defer { loadingEpisodes = false }
        guard let result = try? await LaMovieAPI.episodes(seriesId: item.id, season: season) else { return }
        seasons = result.seasons
        if season == nil { season = result.seasons.first }
        episodes = result.episodes
    }
}

private struct EpisodeRow: View {
    let episode: Episode
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Brand.card
                .frame(width: 150, height: 84)
                .overlay {
                    CachedAsyncImage(url: episode.stillURL, category: .episode) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "play.rectangle")
                            .foregroundStyle(.white.opacity(0.25))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(hovering ? 0.6 : 0), lineWidth: 1.5)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text("\(episode.episodeNumber). Episodio \(episode.episodeNumber)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                if let runtime = episode.runtimeText {
                    Text(runtime).font(.caption).foregroundStyle(.white.opacity(0.45))
                }
                if !episode.overview.isEmpty {
                    Text(episode.overview)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.white.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

#Preview {
    HomeView()
}
