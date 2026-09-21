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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    catalog
                } else {
                    SearchResultsView(state: search.state)
                }
            }
            .background(Color.black)
            .navigationDestination(for: CatalogItem.self) { DetailView(item: $0) }
            .navigationDestination(for: PlaybackTarget.self) { PlayerLoaderView(target: $0) }
            .hidingNavigationBar()
        }
        .preferredColorScheme(.dark)
        .task { await model.load() }
        .task(id: query) { await search.run(query) }
    }

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
        .padding(10)
        .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var catalog: some View {
        Group {
            switch model.state {
            case .loading where model.shelves.isEmpty:
                ProgressView("Cargando catálogo…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                    Text("No se pudo cargar el catálogo").font(.headline)
                    Button("Reintentar") { Task { await model.load() } }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                content
            }
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if let featured = model.featured {
                    HeroView(item: featured)
                }
                ForEach(model.shelves) { shelf in
                    ShelfView(shelf: shelf)
                }
            }
            .padding(.bottom, 32)
        }
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12, alignment: .top)], alignment: .leading, spacing: 16) {
                    ForEach(items) { item in
                        NavigationLink(value: item) { PosterCard(item: item) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(20)
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

            LinearGradient(colors: [.clear, .black], startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 10) {
                Text("LaMovie")
                    .font(.caption.weight(.heavy))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.7))
                Text(item.displayTitle)
                    .font(.system(size: 32, weight: .bold))
                    .lineLimit(2)
                MetaRow(item: item)
                NavigationLink(value: item) {
                    Label("Ver ahora", systemImage: "play.fill")
                        .font(.headline)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(.white, in: Capsule())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
        .frame(height: 380)
    }
}

// MARK: - Rows

private struct ShelfView: View {
    let shelf: Shelf

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(shelf.title)
                .font(.title3.weight(.bold))
                .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(shelf.items) { item in
                        NavigationLink(value: item) { PosterCard(item: item) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

private struct PosterCard: View {
    let item: CatalogItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color(white: 0.15)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay {
                    AsyncImage(url: item.images.posterURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "film").foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {
                    if let rating = item.ratingText {
                        Label(rating, systemImage: "star.fill")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.7), in: Capsule())
                            .foregroundStyle(.yellow)
                            .padding(6)
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
        .frame(width: 130)
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

    private var isSeries: Bool { item.kind != .movies }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Color(white: 0.1)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        AsyncImage(url: item.images.backdropURL ?? item.images.posterURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.clear
                        }
                    }
                    .clipped()

                VStack(alignment: .leading, spacing: 14) {
                    Text(item.displayTitle).font(.largeTitle.bold())
                    MetaRow(item: item)

                    if !item.genreNames.isEmpty {
                        Text(item.genreNames.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if !isSeries {
                        NavigationLink(value: PlaybackTarget(postId: item.id, title: item.displayTitle)) {
                            Label("Reproducir", systemImage: "play.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(.white, in: RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(.black)
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
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: 720, alignment: .leading)
            }
        }
        .background(Color.black)
        .navigationTitle(item.displayTitle)
        .task(id: season) { await loadEpisodes() }
    }

    @ViewBuilder
    private var episodesSection: some View {
        HStack {
            Text("Episodios").font(.title3.weight(.bold))
            Spacer()
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
            NavigationLink(value: PlaybackTarget(postId: episode.id, title: "\(item.displayTitle) · T\(episode.seasonNumber) E\(episode.episodeNumber)")) {
                EpisodeRow(episode: episode)
            }
            .buttonStyle(.plain)
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
                .clipShape(RoundedRectangle(cornerRadius: 8))
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
