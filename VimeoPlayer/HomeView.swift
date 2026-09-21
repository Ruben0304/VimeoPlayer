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

    var featured: CatalogItem? {
        shelves.first { $0.id == "movies" }?.items.first { $0.images.backdropURL != nil }
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

@MainActor
final class SearchViewModel: ObservableObject {
    enum State { case idle, tooShort, loading, results([CatalogItem]), empty, failed }

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

struct HomeView: View {
    @StateObject private var search = SearchViewModel()
    @State private var query = ""

    @StateObject private var model = HomeViewModel()

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                if isSearching {
                    SearchResultsView(state: search.state)
                } else {
                    catalog
                }
                searchBar
            }
            .navigationDestination(for: CatalogItem.self) { DetailView(item: $0) }
            .navigationDestination(for: PlaybackTarget.self) { PlayerLoaderView(target: $0) }
            .hidingNavigationBar()
        }
        .preferredColorScheme(.dark)
        .task { await model.load() }
        .task(id: query) { await search.run(query) }
    }

    /// Flota sobre el contenido, como la barra de búsqueda de la app Apple TV.
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Buscar películas, series y animes", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glass(in: Capsule(), interactive: true)
        .frame(maxWidth: 560)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var catalog: some View {
        switch model.state {
        case .loading where model.shelves.isEmpty:
            ProgressView("Cargando catálogo…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            VStack(spacing: 14) {
                Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                Text("No se pudo cargar el catálogo").font(.headline)
                Button { Task { await model.load() } } label: {
                    GlassButtonLabel(title: "Reintentar", systemImage: "arrow.clockwise", prominent: true)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            content
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                if let featured = model.featured {
                    HeroView(item: featured)
                } else {
                    Color.clear.frame(height: 64)
                }
                ForEach(model.shelves) { shelf in
                    ShelfView(shelf: shelf)
                }
            }
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)
        .refreshable { await model.load() }
    }
}

private extension View {
    @ViewBuilder
    func hidingNavigationBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }
}

// MARK: - Search results

private struct SearchResultsView: View {
    let state: SearchViewModel.State

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .tooShort:
            message("Escribe al menos 3 caracteres", systemImage: "text.cursor")
        case .empty:
            message("No se encontraron resultados", systemImage: "magnifyingglass")
        case .failed:
            message("No se pudo completar la búsqueda", systemImage: "wifi.exclamationmark")
        case .results(let items):
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 14, alignment: .top)], alignment: .leading, spacing: 20) {
                    ForEach(items) { item in
                        NavigationLink(value: item) { PosterCard(item: item) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 80)
                .padding(.bottom, 24)
            }
        }
    }

    private func message(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.largeTitle)
            Text(text).font(.headline)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Hero

private struct HeroView: View {
    let item: CatalogItem

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color(white: 0.1)
                .overlay {
                    AsyncImage(url: item.images.backdropURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                }
                .clipped()

            LinearGradient(stops: [
                .init(color: .black.opacity(0.35), location: 0),
                .init(color: .clear, location: 0.3),
                .init(color: .black.opacity(0.85), location: 0.85),
                .init(color: .black, location: 1),
            ], startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 12) {
                Text("ESTRENO · \(item.kind.label.uppercased())")
                    .font(.caption.weight(.heavy))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.75))
                Text(item.displayTitle)
                    .font(.system(size: 44, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                MetaRow(item: item)
                if !item.overview.isEmpty {
                    Text(item.overview)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(3)
                        .frame(maxWidth: 560, alignment: .leading)
                }
                HStack(spacing: 12) {
                    NavigationLink(value: PlaybackTarget(postId: item.id, title: item.displayTitle)) {
                        GlassButtonLabel(title: "Reproducir", systemImage: "play.fill", prominent: true)
                    }
                    NavigationLink(value: item) {
                        GlassIconLabel(systemImage: "info", size: 46)
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(24)
        }
        .frame(height: 520)
    }
}

// MARK: - Rows

private struct ShelfView: View {
    let shelf: Shelf

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(shelf.title)
                .font(.title2.weight(.bold))
                .padding(.horizontal, 24)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(shelf.items) { item in
                        NavigationLink(value: item) { PosterCard(item: item) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }
}

private struct PosterCard: View {
    let item: CatalogItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color(white: 0.15)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay {
                    AsyncImage(url: item.images.posterURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "film").foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 10, y: 6)
                .overlay(alignment: .topTrailing) {
                    if let rating = item.ratingText {
                        Label(rating, systemImage: "star.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.yellow)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .glass(in: Capsule())
                            .padding(8)
                    }
                }
            Text(item.displayTitle)
                .font(.caption.weight(.semibold))
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            if let year = item.year {
                Text(year).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 140)
    }
}

private struct MetaRow: View {
    let item: CatalogItem

    var body: some View {
        HStack(spacing: 8) {
            if let rating = item.ratingText {
                Label(rating, systemImage: "star.fill").foregroundStyle(.yellow)
            }
            Text(([item.kind.label] + [item.metaLine]).filter { !$0.isEmpty }.joined(separator: " · "))
                .foregroundStyle(.white.opacity(0.8))
        }
        .font(.subheadline.weight(.medium))
    }
}

// MARK: - Detail

struct DetailView: View {
    let item: CatalogItem

    @State private var seasons: [Int] = []
    @State private var season: Int?
    @State private var episodes: [Episode] = []
    @State private var loadingEpisodes = false
    @State private var downloadTarget: PlaybackTarget?
    @State private var seasonRequest: SeasonDownloadRequest?

    private var isSeries: Bool { item.kind != .movies }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 16) {
                    MetaRow(item: item)

                    if !item.genreNames.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(item.genreNames, id: \.self) { GlassChip(text: $0) }
                            }
                        }
                    }

                    if !isSeries {
                        HStack(spacing: 12) {
                            NavigationLink(value: PlaybackTarget(postId: item.id, title: item.displayTitle)) {
                                GlassButtonLabel(title: "Reproducir", systemImage: "play.fill", prominent: true)
                            }
                            Button {
                                downloadTarget = PlaybackTarget(postId: item.id, title: item.displayTitle)
                            } label: {
                                GlassButtonLabel(title: "Descargar", systemImage: "arrow.down.circle")
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    if let tagline = item.tagline, !tagline.isEmpty {
                        Text(tagline).italic().foregroundStyle(.secondary)
                    }
                    if !item.overview.isEmpty {
                        Text(item.overview).font(.body)
                    }

                    if isSeries { episodesSection }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 40)
                .frame(maxWidth: 820, alignment: .leading)
            }
        }
        .background(Color.black)
        .navigationTitle(item.displayTitle)
        .task(id: season) { await loadEpisodes() }
        .sheet(item: $downloadTarget) { DownloadSheet(target: $0) }
        .sheet(item: $seasonRequest) { SeasonDownloadSheet(request: $0) }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            Color(white: 0.1)
                .overlay {
                    AsyncImage(url: item.images.backdropURL ?? item.images.posterURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                }
                .clipped()
            LinearGradient(colors: [.clear, .black], startPoint: .center, endPoint: .bottom)
            Text(item.displayTitle)
                .font(.system(size: 38, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxHeight: 460)
    }

    @ViewBuilder
    private var episodesSection: some View {
        HStack {
            Text("Episodios").font(.title2.weight(.bold))
            Spacer()
            if let season, !episodes.isEmpty {
                Button {
                    seasonRequest = SeasonDownloadRequest(seriesTitle: item.displayTitle, season: season, episodes: episodes)
                } label: {
                    Label("Descargar temporada", systemImage: "arrow.down.circle")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glass(in: Capsule(), interactive: true)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            if seasons.count > 1 {
                Picker("Temporada", selection: $season) {
                    ForEach(seasons, id: \.self) { Text("Temporada \($0)").tag(Optional($0)) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.top, 8)

        if loadingEpisodes && episodes.isEmpty {
            ProgressView().frame(maxWidth: .infinity)
        }
        ForEach(episodes) { episode in
            let title = "\(item.displayTitle) · T\(episode.seasonNumber) E\(episode.episodeNumber)"
            HStack(spacing: 8) {
                NavigationLink(value: PlaybackTarget(postId: episode.id, title: title)) {
                    EpisodeRow(episode: episode)
                }
                .buttonStyle(.plain)
                Button {
                    downloadTarget = PlaybackTarget(postId: episode.id, title: title)
                } label: {
                    GlassIconLabel(systemImage: "arrow.down", size: 40)
                }
                .buttonStyle(.plain)
                .help("Descargar")
            }
            .padding(8)
            .glass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Color(white: 0.15)
                .frame(width: 128, height: 72)
                .overlay {
                    AsyncImage(url: episode.stillURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "play.rectangle").foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("\(episode.episodeNumber). Episodio \(episode.episodeNumber)")
                    .font(.subheadline.weight(.semibold))
                if let runtime = episode.runtimeText {
                    Text(runtime).font(.caption).foregroundStyle(.secondary)
                }
                if !episode.overview.isEmpty {
                    Text(episode.overview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    HomeView()
}
