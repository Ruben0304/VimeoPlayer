import SwiftUI

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
        async let updated = fetch("series-updated", "Series actualizadas", .tvshows, orderBy: "post_modified")
        async let animes = fetch("animes", "Animes recién añadidos", .animes)

        // Una fila que falla no debe tumbar el resto de la pantalla.
        let loaded = await [movies, series, updated, animes].compactMap { $0 }
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

    /// Se llama con cada cambio del texto; la tarea anterior se cancela sola.
    func run(_ raw: String) async {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { state = .idle; return }
        if query.count < 3 { state = .tooShort; return }

        state = .loading
        try? await Task.sleep(for: .milliseconds(400))
        if Task.isCancelled { return }
        do {
            let items = try await LaMovieAPI.search(query)
            if Task.isCancelled { return }
            state = items.isEmpty ? .empty : .results(items)
        } catch {
            if Task.isCancelled { return }
            state = .failed
        }
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
private typealias PlatformImage = NSImage
#else
private typealias PlatformImage = UIImage
#endif

/// Cache en memoria por URL: evita que el póster/backdrop vuelva a descargarse (y
/// parpadee) cuando pasa de la tarjeta a la animación de expansión y a la ficha.
@MainActor
private final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, PlatformImage>()

    func image(for url: URL) -> PlatformImage? { cache.object(forKey: url as NSURL) }
    func insert(_ image: PlatformImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }
}

/// Componente de imagen remota con cache en memoria: una vez cargada, reaparece al
/// instante en cualquier otra vista que pida la misma URL, sin volver a mostrar el
/// placeholder — clave para que la transición póster → ficha no parpadee.
private struct PosterImage: View {
    let url: URL?
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
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let loaded = PlatformImage(data: data) else { return }
        ImageCache.shared.insert(loaded, for: url)
        image = loaded
    }
}

/// Ruta de navegación compartida: permite que `PosterCard` empuje la navegación
/// desde dentro del mismo botón que dispara la animación de expansión.
@MainActor
final class NavigationRouter: ObservableObject {
    @Published var path = NavigationPath()
}

/// Dimensiones de la tarjeta de detalle, compartidas con la animación de expansión
/// para que la portada termine exactamente donde `DetailView` la va a mostrar.
enum DetailCard {
    static let cornerRadius: CGFloat = 0
    static let topMargin: CGFloat = 0
    static let horizontalMargin: CGFloat = 0
    static let contentHorizontalPadding: CGFloat = 48
}

/// Coordina la animación de "expandir" un póster hasta la tarjeta de detalle al abrirlo.
@MainActor
final class PosterTransition: ObservableObject {
    struct Snapshot {
        let posterURL: URL?
        let backdropURL: URL?
        let frame: CGRect
    }

    @Published fileprivate(set) var snapshot: Snapshot?
    /// La ficha se muestra como tarjeta flotante sobre el catálogo, no empujada.
    @Published private(set) var presentedItem: CatalogItem?
    /// Área visible del panel de contenido (sin el sidebar), en coordenadas globales.
    @Published var contentFrame: CGRect = .zero

    func open(_ item: CatalogItem, posterURL: URL?, backdropURL: URL?, frame: CGRect) {
        guard frame != .zero else { return }
        snapshot = Snapshot(posterURL: posterURL, backdropURL: backdropURL, frame: frame)
        // El scrim y la tarjeta se atenúan junto con el crecimiento del póster, en
        // vez de aparecer de golpe detrás de él.
        withAnimation(.easeOut(duration: 0.4)) {
            presentedItem = item
        }
    }

    func dismiss() {
        withAnimation(.easeInOut(duration: 0.22)) {
            presentedItem = nil
        }
    }

    fileprivate func clear() {
        snapshot = nil
    }
}

/// Clon de la portada que crece desde el póster tocado hasta encajar exactamente
/// en la cabecera de `DetailView`, con transición cruzada póster → backdrop.
private struct ExpandingPosterOverlay: View {
    @ObservedObject var transition: PosterTransition
    @State private var expanded = false
    @State private var fadingOut = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let snapshot = transition.snapshot {
                let target = targetRect(in: transition.contentFrame)
                // Escala que hace lucir el contenido (dibujado siempre a tamaño final)
                // como si tuviera el tamaño del póster de origen — así nunca se
                // relayoutea la imagen durante la animación, solo se transforma.
                let scaleX = target.width > 0 ? snapshot.frame.width / target.width : 1
                let scaleY = target.height > 0 ? snapshot.frame.height / target.height : 1
                let restRadius = scaleX > 0 ? 14 / scaleX : 14

                ZStack {
                    PosterImage(url: snapshot.posterURL)
                        .aspectRatio(contentMode: .fill)
                        .opacity(expanded ? 0 : 1)

                    PosterImage(url: snapshot.backdropURL ?? snapshot.posterURL)
                        .aspectRatio(contentMode: .fill)
                        .opacity(expanded ? 1 : 0)
                }
                .compositingGroup()
                .frame(width: target.width, height: target.height)
                .clipShape(
                    RoundedRectangle(cornerRadius: expanded ? DetailCard.cornerRadius : restRadius, style: .continuous)
                )
                .shadow(color: .black.opacity(expanded ? 0.45 : 0.28), radius: expanded ? 34 : 10, y: expanded ? 18 : 6)
                .scaleEffect(x: expanded ? 1 : scaleX, y: expanded ? 1 : scaleY, anchor: .center)
                .position(
                    x: expanded ? target.midX : snapshot.frame.midX,
                    y: expanded ? target.midY : snapshot.frame.midY
                )
                .opacity(fadingOut ? 0 : 1)
                .onAppear { runAnimation() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// La misma cabecera a pantalla completa que `DetailView` dibuja arriba del todo.
    private func targetRect(in contentFrame: CGRect) -> CGRect {
        guard contentFrame != .zero else { return .zero }
        let cardWidth = contentFrame.width
        let headerHeight = cardWidth * 9 / 16
        return CGRect(
            x: contentFrame.minX,
            y: contentFrame.minY,
            width: cardWidth,
            height: headerHeight
        )
    }

    private func runAnimation() {
        expanded = false
        fadingOut = false
        // Un spring, no una curva de tiempo fija: se siente nativo y el `completion`
        // real evita el desfase de un `DispatchQueue` con una duración adivinada.
        withAnimation(.spring(response: 0.5, dampingFraction: 0.87), completionCriteria: .logicallyComplete) {
            expanded = true
        } completion: {
            withAnimation(.easeOut(duration: 0.18), completionCriteria: .logicallyComplete) {
                fadingOut = true
            } completion: {
                transition.clear()
            }
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @StateObject private var search = SearchViewModel()
    @StateObject private var recentlyViewed = RecentlyViewedStore()
    @State private var query = ""
    @State private var selection: SidebarCategory? = .home
    @State private var showingSettings = false
    @StateObject private var router = NavigationRouter()

    @StateObject private var model = HomeViewModel()
    @StateObject private var moviesModel = CategoryViewModel(kind: .movies)
    @StateObject private var seriesModel = CategoryViewModel(kind: .tvshows)
    @StateObject private var animesModel = CategoryViewModel(kind: .animes)
    @StateObject private var posterTransition = PosterTransition()

    var body: some View {
        ZStack {
            NavigationSplitView {
                sidebar
            } detail: {
                NavigationStack(path: $router.path) {
                    ZStack(alignment: .topTrailing) {
                        AppBackground()

                        catalog

                        // Tarjeta flotante con blur: el catálogo se ve (desenfocado) detrás.
                        if let presented = posterTransition.presentedItem {
                            DetailView(item: presented, onDismiss: { posterTransition.dismiss() })
                                .transition(.opacity)
                        }
                    }
                    // Para que la animación de expansión sepa exactamente dónde
                    // termina la tarjeta de detalle (excluye el ancho del sidebar).
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { posterTransition.contentFrame = geo.frame(in: .global) }
                                .onChange(of: geo.frame(in: .global)) { _, newValue in
                                    posterTransition.contentFrame = newValue
                                }
                        }
                    )
                    .navigationDestination(for: CatalogItem.self) { DetailView(item: $0) }
                    .navigationDestination(for: PlaybackTarget.self) { PlayerLoaderView(target: $0) }
                    .hidingNavigationBar()
                    .ignoresSafeArea(edges: .top)
                }
            }
            .navigationSplitViewStyle(.balanced)

            // El póster tocado crece hasta cubrir toda la ventana mientras se abre la película.
            ExpandingPosterOverlay(transition: posterTransition)
        }
        .environmentObject(posterTransition)
        .environmentObject(router)
        .environmentObject(recentlyViewed)
        .preferredColorScheme(.dark)
        .task { await model.load() }
        .task(id: query) { await search.run(query) }
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
                ForEach(model.shelves) { shelf in
                    ShelfView(shelf: shelf)
                }
            }
            .padding(.top, model.featuredItems.isEmpty ? 24 : 0)
            .padding(.bottom, 56)
        }
        .refreshable { await model.load() }
    }
}

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
    @ObservedObject var recentlyViewed: RecentlyViewedStore
    let onSelectCategory: (SidebarCategory) -> Void

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if isSearching {
                SearchResultsView(state: searchState)
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

// MARK: - Search results

private struct SearchResultsView: View {
    let state: SearchViewModel.State

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .tooShort:
            message("Escribe al menos 3 caracteres", systemImage: "text.cursor")
        case .empty:
            message("No se encontraron resultados", systemImage: "magnifyingglass")
        case .failed:
            message("No se pudo completar la búsqueda", systemImage: "wifi.exclamationmark")
        case .results(let items):
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(items) { item in
                        PosterCard(item: item)
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

// MARK: - Hero

/// Rota automáticamente entre varias películas destacadas, como el banner de Apple TV.
private struct HeroCarousel: View {
    let items: [CatalogItem]
    @State private var index = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            ForEach(Array(items.enumerated()), id: \.element.id) { position, item in
                HeroView(item: item)
                    .opacity(position == index ? 1 : 0)
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
                .animation(.easeOut(duration: 0.25), value: index)
                .padding(.bottom, 20)
            }
        }
        .task(id: items.map(\.id)) { await autoAdvance() }
    }

    private func autoAdvance() async {
        guard items.count > 1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(7))
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.6)) {
                index = (index + 1) % items.count
            }
        }
    }
}

private struct HeroView: View {
    let item: CatalogItem

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { proxy in
                let minY = proxy.frame(in: .global).minY
                let pulledDown = max(0, minY)
                let scrolledUp = min(0, minY)
                Color(white: 0.05)
                    .overlay {
                        AsyncImage(url: item.images.backdropURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.clear
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height + pulledDown + abs(scrolledUp) * 0.3)
                    .offset(y: minY > 0 ? -minY : minY * 0.3)
            }
            .clipped()

            LinearGradient(
                colors: [.clear, .clear, Brand.background.opacity(0.5), Brand.background],
                startPoint: .top, endPoint: .bottom
            )
            LinearGradient(
                colors: [Brand.background.opacity(0.75), .clear],
                startPoint: .leading, endPoint: .trailing
            )

            VStack(alignment: .leading, spacing: 14) {
                TitleLogo(item: item, textFont: .system(size: 42, weight: .bold, design: .rounded))

                MetaRow(item: item)

                if !item.overview.isEmpty {
                    Text(item.overview)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                        .frame(maxWidth: 520, alignment: .leading)
                }

                HStack(spacing: 14) {
                    PlayButton(target: PlaybackTarget(postId: item.id, title: item.displayTitle)) {
                        Label("Reproducir", systemImage: "play.fill")
                            .font(.headline)
                            .padding(.horizontal, 26)
                            .padding(.vertical, 12)
                            .background(.white, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)

                    NavigationLink(value: item) {
                        Label("Más información", systemImage: "info.circle")
                            .font(.headline)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 12)
                            .foregroundStyle(.white)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Capsule())
                }
                .padding(.top, 4)
            }
            .padding(EdgeInsets(top: 20, leading: 36, bottom: 40, trailing: 36))
        }
        .frame(height: 620)
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
    @State private var posterFrame: CGRect = .zero
    @State private var tmdbPosterURL: URL?
    @EnvironmentObject private var transition: PosterTransition
    @EnvironmentObject private var recentlyViewed: RecentlyViewedStore

    private var posterURL: URL? { tmdbPosterURL ?? item.images.posterURL }

    var body: some View {
        Button {
            transition.open(item, posterURL: posterURL, backdropURL: item.images.backdropURL, frame: posterFrame)
            recentlyViewed.add(item)
        } label: {
            cardBody
        }
        .buttonStyle(.plain)
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
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { posterFrame = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { _, newValue in posterFrame = newValue }
                }
            )
            .frame(width: 190)
            .animation(.easeInOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
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
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .navigationTitle(item.displayTitle)
        .task(id: season) { await loadEpisodes() }
        .task(id: item.id) { await loadTMDBDetails() }
        .task(id: item.id) { await loadQuality() }
        .sheet(item: $downloadTarget) { DownloadSheet(target: $0) }
        .sheet(item: $seasonRequest) { SeasonDownloadSheet(request: $0) }
    }

    private func loadTMDBDetails() async {
        async let details = TMDBService.shared.details(for: item)
        async let images = TMDBService.shared.images(for: item)
        let (resolvedDetails, resolvedImages) = await (details, images)
        tmdbDetails = resolvedDetails
        tmdbBackdropURL = resolvedImages.backdrop ?? resolvedImages.poster
    }

    /// Solo para películas: los episodios tienen su propia calidad por enlace.
    private func loadQuality() async {
        guard !isSeries else { return }
        let downloads = (try? await LaMovieAPI.downloads(postId: item.id)) ?? []
        qualityTiers = downloads.qualityTiers
        hasWebDL = downloads.contains { $0.category == .webDL }
    }

    /// Ficha a pantalla completa cuya cabecera coincide en tamaño con el destino
    /// de la animación de expansión del póster.
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Color(white: 0.05)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        PosterImage(url: tmdbBackdropURL ?? item.images.backdropURL ?? item.images.posterURL)
                            .aspectRatio(contentMode: .fill)
                            .clipped()
                    }

                LinearGradient(
                    colors: [.clear, .clear, .black.opacity(0.55), .black.opacity(0.92)],
                    startPoint: .top, endPoint: .bottom
                )

                // Título, metadatos y botón de reproducir sobre la portada, como en
                // la cabecera de un servicio de streaming.
                VStack(alignment: .leading, spacing: 16) {
                    TitleLogo(item: item, textFont: .system(size: 40, weight: .bold, design: .rounded))
                        .shadow(color: .black.opacity(0.6), radius: 12, y: 4)
                    MetaRow(item: item)

                    if !qualityTiers.isEmpty || hasWebDL {
                        HStack(spacing: 6) {
                            ForEach(qualityTiers, id: \.self) { QualityBadge(label: $0.label) }
                            if hasWebDL { QualityBadge(label: "WEB-DL") }
                        }
                    }

                    if !item.genreNames.isEmpty {
                        Text(item.genreNames.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    if !isSeries {
                        HStack(spacing: 12) {
                            PlayButton(target: PlaybackTarget(postId: item.id, title: item.displayTitle)) {
                                Label("Reproducir", systemImage: "play.fill")
                                    .font(.headline)
                                    .padding(.horizontal, 28)
                                    .padding(.vertical, 14)
                                    .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .foregroundStyle(.black)
                            }
                            .buttonStyle(.plain)

                            Button {
                                downloadTarget = PlaybackTarget(postId: item.id, title: item.displayTitle)
                            } label: {
                                Image(systemName: "arrow.down")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .frame(width: 50, height: 50)
                                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }

                    if let tagline = item.tagline, !tagline.isEmpty {
                        Text(tagline)
                            .italic()
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, DetailCard.contentHorizontalPadding)
                .padding(.bottom, 36)
            }

            VStack(alignment: .leading, spacing: 18) {
                if !overviewText.isEmpty {
                    Text(overviewText)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.85))
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
                                    AsyncImage(url: member.profileURL) { image in
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
                PlayButton(target: PlaybackTarget(postId: episode.id, title: episodeTitle)) {
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
                    AsyncImage(url: episode.stillURL) { image in
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
