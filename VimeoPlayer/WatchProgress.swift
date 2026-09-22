import SwiftUI

/// Contexto que acompaña a un `PlaybackTarget` para poder guardar y retomar el progreso.
struct WatchInfo: Hashable {
    let item: CatalogItem
    var season: Int?
    var episode: Int?
    var episodeTitle: String?

    /// "T1 E2 · Título" (series) o nil (películas).
    var episodeLabel: String? {
        guard let season, let episode else { return nil }
        return "T\(season) E\(episode)"
    }
}

/// Lo último que se vio de un título: dónde se quedó (temporada, episodio y segundo).
struct WatchEntry: Codable, Identifiable, Hashable {
    let item: CatalogItem
    /// Post reproducido: la película o el episodio concreto.
    var postId: Int
    var season: Int?
    var episode: Int?
    var episodeTitle: String?
    var position: Double
    var duration: Double
    var updatedAt: Date

    var id: Int { item.id }
    var fraction: Double { duration > 0 ? min(max(position / duration, 0), 1) : 0 }
    var remainingMinutes: Int { max(1, Int(((duration - position) / 60).rounded(.up))) }

    var info: WatchInfo { WatchInfo(item: item, season: season, episode: episode, episodeTitle: episodeTitle) }

    var target: PlaybackTarget {
        var title = item.displayTitle
        if let label = info.episodeLabel { title += " · \(label)" }
        return PlaybackTarget(postId: postId, title: title, watch: info)
    }
}

/// Historial "Continuar viendo", guardado en local (`UserDefaults`) y compartido entre la ventana
/// principal y la del reproductor.
@MainActor
final class WatchProgressStore: ObservableObject {
    static let shared = WatchProgressStore()

    @Published private(set) var entries: [WatchEntry]
    /// Títulos reproducidos de verdad (más recientes primero), también los ya terminados,
    /// que salen de `entries`. Alimenta "Porque viste…".
    @Published private(set) var watched: [CatalogItem]

    private let defaultsKey = "watchProgress"
    private let watchedKey = "watchedHistory"
    private let watchedLimit = 10
    private let limit = 30
    /// Menos que esto no cuenta como "empezado"; más que esta fracción se da por terminado.
    private let minimumSeconds = 20.0
    private let finishedFraction = 0.95

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([WatchEntry].self, from: data) {
            entries = decoded.sorted { $0.updatedAt > $1.updatedAt }
        } else {
            entries = []
        }
        if let data = UserDefaults.standard.data(forKey: watchedKey),
           let decoded = try? JSONDecoder().decode([CatalogItem].self, from: data) {
            watched = decoded
        } else {
            // Primera vez con historial: se parte de lo que ya estaba a medias.
            let started = (try? JSONDecoder().decode([WatchEntry].self,
                                                     from: UserDefaults.standard.data(forKey: defaultsKey) ?? Data())) ?? []
            watched = Array(started.sorted { $0.updatedAt > $1.updatedAt }.map(\.item).prefix(watchedLimit))
        }
    }

    /// Segundo desde el que retomar `postId`, si se dejó a medias.
    func resumePosition(forPost postId: Int) -> Double? {
        guard let entry = entries.first(where: { $0.postId == postId }), entry.position > minimumSeconds else { return nil }
        return entry.position
    }

    /// Guarda la posición actual. Al pasar del 95 % el título se da por visto y sale de la lista.
    func record(_ info: WatchInfo, postId: Int, position: Double, duration: Double) {
        guard position.isFinite, duration.isFinite, duration > 0 else { return }
        if position >= minimumSeconds { noteWatched(info.item) }
        if position / duration >= finishedFraction {
            remove(itemID: info.item.id)
            return
        }
        guard position >= minimumSeconds else { return }

        let entry = WatchEntry(
            item: info.item, postId: postId, season: info.season, episode: info.episode,
            episodeTitle: info.episodeTitle, position: position, duration: duration, updatedAt: Date()
        )
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        persist()
    }

    /// Sube el título al frente del historial (solo escribe a disco si cambia algo).
    private func noteWatched(_ item: CatalogItem) {
        guard watched.first?.id != item.id else { return }
        watched.removeAll { $0.id == item.id }
        watched.insert(item, at: 0)
        if watched.count > watchedLimit { watched.removeLast(watched.count - watchedLimit) }
        guard let data = try? JSONEncoder().encode(watched) else { return }
        UserDefaults.standard.set(data, forKey: watchedKey)
    }

    func remove(itemID: Int) {
        guard entries.contains(where: { $0.id == itemID }) else { return }
        entries.removeAll { $0.id == itemID }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

/// Acumula la posición de un reproductor y la vuelca al almacén cada pocos segundos (y al parar).
@MainActor
final class WatchProgressReporter {
    private let target: PlaybackTarget
    private var lastSaved = Date.distantPast

    init?(target: PlaybackTarget?) {
        guard let target, target.watch != nil, target.mediaFire == nil else { return nil }
        self.target = target
    }

    var resumePosition: Double? { WatchProgressStore.shared.resumePosition(forPost: target.postId) }

    func report(position: Double, duration: Double, force: Bool = false) {
        guard let info = target.watch else { return }
        guard force || Date().timeIntervalSince(lastSaved) >= 5 else { return }
        lastSaved = Date()
        WatchProgressStore.shared.record(info, postId: target.postId, position: position, duration: duration)
    }
}

// MARK: - Fila "Continuar viendo"

struct ContinueWatchingShelf: View {
    @ObservedObject var store: WatchProgressStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Continuar viendo")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, HomeLayout.shelfHorizontalPadding)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: HomeLayout.cardSpacing) {
                    ForEach(store.entries) { entry in
                        ContinueCard(entry: entry, store: store)
                    }
                }
                .padding(.horizontal, HomeLayout.shelfHorizontalPadding)
                .padding(.vertical, 8)
            }
        }
    }
}

private struct ContinueCard: View {
    let entry: WatchEntry
    let store: WatchProgressStore

    @State private var hovering = false
    @State private var backdropURL: URL?

    private static let width: CGFloat = 300
    private var imageURL: URL? { backdropURL ?? entry.item.images.backdropURL ?? entry.item.images.posterURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottom) {
                PlayButton(target: entry.target) { thumbnail }
                    .buttonStyle(.plain)
                progressBar
            }
            .overlay(alignment: .topTrailing) { menu }

            VStack(alignment: .leading, spacing: 3) {
                Text(caption)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Text("Quedan \(entry.remainingMinutes) min")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: Self.width)
        .task(id: entry.item.id) {
            backdropURL = await TMDBService.shared.images(for: entry.item).backdrop
        }
    }

    /// "T1 E2 Título del episodio", o el título de la película.
    private var caption: String {
        guard let label = entry.info.episodeLabel else { return entry.item.displayTitle }
        var text = "\(entry.item.displayTitle) · \(label)"
        if let title = entry.episodeTitle, !title.isEmpty { text += " \(title)" }
        return text
    }

    private var thumbnail: some View {
        Color(white: 0.12)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                PosterImage(url: imageURL, category: .backdrop)
                    .aspectRatio(contentMode: .fill)
                    .clipped()
            }
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .center) {
                TitleLogo(item: entry.item, textFont: .system(size: 18, weight: .bold, design: .rounded))
                    .frame(width: 220, height: 64)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                Image(systemName: "play.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
                    .padding(.leading, 14)
                    .padding(.bottom, 14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.white.opacity(hovering ? 0.95 : 0), lineWidth: 2)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .animation(.easeInOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
            .pointerCursor()
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.25))
                Rectangle().fill(.white).frame(width: proxy.size.width * entry.fraction)
            }
        }
        .frame(height: 3)
        .clipShape(Capsule())
        .padding(.horizontal, 6)
        .padding(.bottom, 5)
        .allowsHitTesting(false)
    }

    private var menu: some View {
        Menu {
            Button("Quitar de Continuar viendo", systemImage: "xmark.circle") {
                store.remove(itemID: entry.item.id)
            }
        } label: {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.black.opacity(0.45), in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .padding(8)
        .opacity(hovering ? 1 : 0.85)
    }
}
