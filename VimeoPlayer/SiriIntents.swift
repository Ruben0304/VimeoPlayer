import AppIntents
import SwiftUI

// MARK: - ¿Está en LaMovie?

/// "¿Ya salió Dune en LaMovie?" / "¿Está la serie Severance en LaMovie?".
struct CheckLaMovieIntent: AppIntent {
    static let title: LocalizedStringResource = "¿Está en LaMovie?"
    static let description = IntentDescription("Dice si una película o serie ya está en LaMovie.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Película o serie", requestValueDialog: "¿Qué película o serie?")
    var item: TitleEntity

    static var parameterSummary: some ParameterSummary {
        Summary("¿Está \(\.$item) en LaMovie?")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        await LocalCatalog.shared.load()
        var entity = item.inCatalog()
        if !entity.isOnLaMovie {
            // Puede haber llegado hace poco: se buscan novedades (como mucho una vez al día).
            await LocalCatalog.shared.updateIfStale()
            entity = entity.inCatalog()
        }
        let poster = await SnippetPoster.load(entity.posterURL)

        if entity.isOnLaMovie {
            let text = "Sí, \(entity.kind.spokenLabel) \(entity.name) ya está en LaMovie."
            return .result(dialog: "\(text)", view: TitleSnippetView(entity: entity, poster: poster, lines: [], action: .open))
        }

        var text = "No, \(entity.kind.spokenLabel) \(entity.name) todavía no está en LaMovie."
        if let release = await entity.streamingDetails()?.upcomingRelease {
            text += " Se estrena el \(release)."
        }
        return .result(dialog: "\(text)", view: TitleSnippetView(entity: entity, poster: poster, lines: [], action: .notify))
    }
}

// MARK: - Dónde ver

/// "¿Dónde puedo ver Dune en España?", "¿Está Dune en HBO Max en algún país?".
/// Datos de JustWatch (vía TMDB), los mismos que "Dónde ver" en la ficha.
struct WhereToWatchIntent: AppIntent {
    static let title: LocalizedStringResource = "Dónde ver"
    static let description = IntentDescription("Dice en qué plataformas y países se puede ver una película o serie.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Película o serie", requestValueDialog: "¿Qué película o serie?")
    var item: TitleEntity

    @Parameter(title: "Plataforma")
    var platform: StreamingPlatform?

    @Parameter(title: "País")
    var country: CountryEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Dónde ver \(\.$item)") {
            \.$platform
            \.$country
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        await LocalCatalog.shared.load()
        let entity = item.inCatalog()
        async let poster = SnippetPoster.load(entity.posterURL)
        let streaming = await entity.streamingDetails()?.streaming ?? [:]
        let answer = WhereToWatchAnswer(name: entity.name, streaming: streaming, platform: platform, country: country)
        return .result(
            dialog: "\(answer.text)",
            view: TitleSnippetView(entity: entity, poster: await poster, lines: answer.lines,
                                   action: entity.isOnLaMovie ? .open : nil)
        )
    }
}

/// La respuesta hablada y las líneas de la tarjeta para `WhereToWatchIntent`.
struct WhereToWatchAnswer {
    var text = ""
    var lines: [SnippetLine] = []

    init(name: String, streaming: [String: StreamingAvailability], platform: StreamingPlatform?, country: CountryEntity?) {
        typealias Streaming = [String: StreamingAvailability]

        guard !streaming.isEmpty else {
            text = "No encontré en qué plataformas se puede ver \(name)."
            return
        }

        if let platform {
            let offering = streaming.countries(offering: platform.matches)
            if let country {
                if let hit = offering.first(where: { $0.code == country.id }) {
                    text = "Sí, en \(country.name) puedes ver \(name) en \(platform.name) (\(Self.list(hit.kinds).lowercased()))."
                    lines = [SnippetLine(label: country.name, value: "\(platform.name) · \(Self.list(hit.kinds))")]
                } else {
                    text = "No, en \(country.name) \(name) no está en \(platform.name)."
                    if let there = streaming[country.id] {
                        let names = Self.providerNames(there.subscription + there.free)
                        text += " Allí está en \(Self.list(names))."
                        lines.append(SnippetLine(label: country.name, value: names.joined(separator: ", ")))
                    }
                    if !offering.isEmpty {
                        let codes = offering.map(\.code)
                        text += " En \(platform.name) sí está en \(Self.countries(codes))."
                        lines.append(SnippetLine(label: platform.name, value: Self.countries(codes, limit: 12)))
                    }
                }
            } else if offering.isEmpty {
                text = "No, \(name) no está en \(platform.name) en ningún país."
                lines = [SnippetLine(label: "Está en", value: Self.providerNames(streaming.allProviders).prefix(8).joined(separator: ", "))]
            } else {
                // El país propio primero, si está.
                let home = CountryEntity.current.id
                let codes = offering.map(\.code).sorted { ($0 == home ? 0 : 1) < ($1 == home ? 0 : 1) }
                let count = codes.count == 1 ? "1 país" : "\(codes.count) países"
                text = "Sí, \(name) está en \(platform.name) en \(count): \(Self.countries(codes))."
                lines = [SnippetLine(label: platform.name, value: Self.countries(codes, limit: 12))]
            }
            return
        }

        let place = country ?? CountryEntity.current
        if let entry = streaming[place.id] {
            var parts: [String] = []
            let subscription = Self.providerNames(entry.subscription)
            let free = Self.providerNames(entry.free)
            if !subscription.isEmpty {
                parts.append("con suscripción en \(Self.list(subscription))")
                lines.append(SnippetLine(label: "Suscripción", value: subscription.joined(separator: ", ")))
            }
            if !free.isEmpty {
                parts.append("gratis en \(Self.list(free))")
                lines.append(SnippetLine(label: "Gratis", value: free.joined(separator: ", ")))
            }
            text = "En \(place.name) puedes ver \(name) \(parts.joined(separator: " y "))."
        } else {
            let codes = streaming.sortedCountries
            text = "En \(place.name) \(name) no está en ninguna plataforma. Sí está en \(Self.countries(codes))."
            lines = [SnippetLine(label: "Disponible en", value: Self.countries(codes, limit: 12))]
        }
    }

    private static let spanish = Locale(identifier: "es")

    /// "Netflix, HBO Max y Prime Video".
    private static func list(_ items: [String]) -> String {
        items.formatted(.list(type: .and).locale(spanish))
    }

    /// Nombres sin repetir, en el orden de TMDB.
    private static func providerNames(_ providers: [StreamingProvider]) -> [String] {
        var seen = Set<String>()
        return providers.map(\.name).filter { seen.insert($0).inserted }
    }

    /// "España, México y 10 más".
    private static func countries(_ codes: [String], limit: Int = 5) -> String {
        let names = codes.prefix(limit).map { [String: StreamingAvailability].countryName($0) }
        let rest = codes.count - names.count
        return rest > 0 ? names.joined(separator: ", ") + " y \(rest) más" : list(names)
    }
}

// MARK: - Acciones de la tarjeta

/// Abre la ficha en la app (o la búsqueda, si el título no está en lamovie).
struct OpenTitleIntent: OpenIntent {
    static let title: LocalizedStringResource = "Abrir en LaMovie"
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Película o serie")
    var target: TitleEntity

    init() {}
    init(target: TitleEntity) { self.target = target }

    @MainActor
    func perform() async throws -> some IntentResult {
        SiriRouter.shared.open(target)
        return .result()
    }
}

/// Apunta el título a "Avísame": sale en Inicio cuando llegue a lamovie.
struct NotifyWhenAvailableIntent: AppIntent {
    static let title: LocalizedStringResource = "Avisarme cuando llegue a LaMovie"
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Película o serie")
    var item: TitleEntity

    init() {}
    init(item: TitleEntity) { self.item = item }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await LocalCatalog.shared.load()
        let entity = item.inCatalog()
        if entity.isOnLaMovie { return .result(dialog: "\(entity.name) ya está en LaMovie.") }
        guard let suggestion = entity.suggestion else { return .result(dialog: "No pude apuntar ese título.") }
        let wanted = WantedTitle(suggestion)
        if !WantedStore.shared.isWanted(wanted.id) { WantedStore.shared.toggle(wanted) }
        return .result(dialog: "Listo. Cuando \(entity.name) llegue a LaMovie aparecerá en Inicio.")
    }
}

/// Lleva a la app adonde pidió Siri; `HomeView` lo recoge al aparecer o al instante.
@MainActor
final class SiriRouter: ObservableObject {
    static let shared = SiriRouter()

    enum Destination: Equatable {
        case item(CatalogItem)
        case search(String)
    }

    @Published var pending: Destination?

    func open(_ entity: TitleEntity) {
        pending = entity.catalogItem.map(Destination.item) ?? .search(entity.name)
    }
}

// MARK: - Frases

/// Frases para Siri. Deben llevar el nombre de la app y no admiten texto libre: el título se
/// pide después ("¿Qué película o serie?"). La versión en español está en `AppShortcuts.xcstrings`.
struct LaMovieShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CheckLaMovieIntent(),
            phrases: [
                "Is it out on \(.applicationName)?",
                "Is it on \(.applicationName)?",
                "Is it already on \(.applicationName)?",
                "Search \(.applicationName)",
                "Is \(\.$item) out on \(.applicationName)?",
                "Is \(\.$item) on \(.applicationName)?",
            ],
            shortTitle: "¿Está en LaMovie?",
            systemImageName: "film"
        )
        AppShortcut(
            intent: WhereToWatchIntent(),
            phrases: [
                "Where to watch with \(.applicationName)",
                "Where can I watch it with \(.applicationName)?",
                "What platforms is it on in \(.applicationName)?",
                "Is it on \(\.$platform) in \(.applicationName)?",
                "Where to watch \(\.$item) with \(.applicationName)",
            ],
            shortTitle: "Dónde ver",
            systemImageName: "tv"
        )
    }
}

// MARK: - Tarjeta

struct SnippetLine: Hashable {
    let label: String
    let value: String
}

/// Tarjeta que Siri muestra con la respuesta: portada, título y, según el caso, las
/// plataformas y un botón para abrirlo o para que avise cuando llegue.
struct TitleSnippetView: View {
    enum Action { case open, notify }

    let entity: TitleEntity
    let poster: Image?
    let lines: [SnippetLine]
    let action: Action?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let poster {
                        poster.resizable().scaledToFill()
                    } else {
                        Image(systemName: "film").font(.title2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 60, height: 90)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(entity.name).font(.headline).lineLimit(2)
                    Text([entity.kind.label, entity.year].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                    Label(entity.isOnLaMovie ? "En LaMovie" : "Aún no está en LaMovie",
                          systemImage: entity.isOnLaMovie ? "checkmark.circle.fill" : "clock")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(entity.isOnLaMovie ? .green : .orange)
                }
                Spacer(minLength: 0)
            }

            ForEach(lines, id: \.self) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.label).font(.caption).foregroundStyle(.secondary)
                    Text(line.value).font(.subheadline)
                }
            }

            switch action {
            case .open:
                Button(intent: OpenTitleIntent(target: entity)) {
                    Label("Abrir en LaMovie", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            case .notify:
                Button(intent: NotifyWhenAvailableIntent(item: entity)) {
                    Label("Avísame cuando llegue", systemImage: "bell").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            case nil:
                EmptyView()
            }
        }
        .padding()
    }
}

/// Las tarjetas de Siri no cargan imágenes remotas por sí solas: la portada se descarga antes.
enum SnippetPoster {
    static func load(_ url: URL?) async -> Image? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        #if os(macOS)
        return NSImage(data: data).map(Image.init(nsImage:))
        #else
        return UIImage(data: data).map(Image.init(uiImage:))
        #endif
    }
}

// MARK: - Textos

extension ContentKind {
    /// Cómo lo dice Siri: "la película", "la serie"…
    var spokenLabel: String {
        switch self {
        case .movies: "la película"
        case .tvshows: "la serie"
        case .animes: "el anime"
        case .novels: "la novela"
        case .wwe: "el evento"
        }
    }
}

extension TMDBDetails {
    /// "18 de diciembre de 2026" si el estreno aún no ha llegado.
    var upcomingRelease: String? {
        guard let releaseDate,
              let date = try? Date(releaseDate, strategy: .iso8601.year().month().day()),
              date > .now else { return nil }
        return date.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(Locale(identifier: "es")))
    }
}
