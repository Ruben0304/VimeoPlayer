#if os(macOS)
import AppKit
import SwiftUI
import VLCKitSPM

/// Reproductor para lo que AVFoundation no lee (MKV): VLCKit con controles propios en Liquid Glass.
@MainActor
final class MKVPlayerModel: ObservableObject {
    struct TrackOption: Identifiable, Hashable {
        let id: Int32
        let name: String
    }

    let player = VLCMediaPlayer()

    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = true
    @Published private(set) var currentTime = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var audioTracks: [TrackOption] = []
    @Published private(set) var subtitleTracks: [TrackOption] = []
    @Published private(set) var selectedAudio: Int32 = -1
    @Published private(set) var selectedSubtitle: Int32 = -1
    /// Hasta dónde se puede saltar (0...1). `nil` si todo el archivo está disponible.
    @Published private(set) var availableFraction: Double?
    @Published private(set) var statusText: String?
    @Published var errorText: String?

    /// Calidades (si la fuente las ofrece, como el stream con proxy); vacío si no hay que elegir.
    @Published private(set) var qualities: [QualityOption] = []
    @Published private(set) var selectedQuality = QualityOption.automatic.id

    /// Progreso de la fuente (si es un RAR que se descomprime a la vez): decodificado, bajado, total.
    var sourceProgress: (@Sendable () -> RARVideoStream.Progress)?
    /// Texto de estado que depende de la posición (p. ej. el buffer del proxy).
    var statusProvider: (@Sendable (Double) async -> String?)?
    /// URL a reproducir para una calidad.
    var qualityURLProvider: (@Sendable (QualityOption) async -> URL)?

    private var pendingSeek: Double?
    /// Guarda el progreso para "Continuar viendo" cuando el título lo pide.
    var progress: WatchProgressReporter?

    private var updateTask: Task<Void, Never>?
    private var lastDownloaded: Int64 = 0
    private var lastSample = Date()

    func play(url: URL, startAt: Double? = nil) {
        let media = VLCMedia(url: url)
        player.media = media
        player.play()
        pendingSeek = startAt.flatMap { $0 > 1 ? $0 : nil }
        startUpdates()
    }

    func setQualities(_ options: [QualityOption]) {
        qualities = options
        selectedQuality = QualityOption.automatic.id
    }

    /// Cambia de calidad recargando en el mismo punto (VLC conserva el audio y los subtítulos por idioma).
    func choose(quality: QualityOption) {
        guard quality.id != selectedQuality, let provider = qualityURLProvider else { return }
        selectedQuality = quality.id
        let position = currentTime
        Task { [weak self] in
            let url = await provider(quality)
            self?.play(url: url, startAt: position)
        }
    }

    func stop() {
        if duration > 0 { progress?.report(position: currentTime, duration: duration, force: true) }
        updateTask?.cancel()
        updateTask = nil
        player.stop()
        player.media = nil
    }

    func togglePlay() {
        if player.isPlaying { player.pause() } else { player.play() }
        isPlaying = player.isPlaying
    }

    func skip(seconds: Int32) {
        seek(to: currentTime + Double(seconds))
    }

    /// Salta a `seconds`, sin pasar de lo ya disponible.
    func seek(to seconds: Double) {
        guard duration > 0 else { return }
        var target = max(0, seconds)
        if let available = availableFraction { target = min(target, max(0, available * duration - 5)) }
        target = min(target, duration)
        player.time = VLCTime(int: Int32(target * 1000))
        currentTime = target
    }

    func selectAudio(_ index: Int32) {
        player.currentAudioTrackIndex = index
        selectedAudio = index
    }

    func selectSubtitle(_ index: Int32) {
        player.currentVideoSubTitleIndex = index
        selectedSubtitle = index
    }

    // MARK: - Estado

    private func startUpdates() {
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                if let self, let provider = self.statusProvider {
                    let text = await provider(self.currentTime)
                    self.statusText = text
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func refresh() {
        isPlaying = player.isPlaying
        let state = player.state
        isBuffering = state == .buffering || state == .opening
        if state == .error { errorText = "VLC no pudo reproducir el archivo." }

        currentTime = Double(player.time.intValue) / 1000
        let length = Double(player.media?.length.intValue ?? 0) / 1000
        if length > 0 { duration = length }
        if state == .playing, pendingSeek == nil, duration > 0 { progress?.report(position: currentTime, duration: duration) }
        if let target = pendingSeek, state == .playing, length > 0 {
            pendingSeek = nil
            player.time = VLCTime(int: Int32(target * 1000))
        }

        audioTracks = zip(player.audioTrackIndexes, player.audioTrackNames).compactMap { index, name in
            guard let index = index as? NSNumber, let name = name as? String, index.int32Value >= 0 else { return nil }
            return TrackOption(id: index.int32Value, name: name)
        }
        subtitleTracks = zip(player.videoSubTitlesIndexes, player.videoSubTitlesNames).compactMap { index, name in
            guard let index = index as? NSNumber, let name = name as? String else { return nil }
            return TrackOption(id: index.int32Value, name: index.int32Value == -1 ? "Sin subtítulos" : name)
        }
        selectedAudio = player.currentAudioTrackIndex
        selectedSubtitle = player.currentVideoSubTitleIndex

        if let progress = sourceProgress?() {
            availableFraction = progress.isFinished ? nil : Double(progress.decodedBytes) / Double(max(progress.totalBytes, 1))
            let now = Date()
            let elapsed = now.timeIntervalSince(lastSample)
            if elapsed >= 1 {
                let speed = Double(progress.downloadedBytes - lastDownloaded) / elapsed
                lastDownloaded = progress.downloadedBytes
                lastSample = now
                statusText = String(format: "Descomprimido %.0f %% · bajando %.0f KB/s",
                                    Double(progress.decodedBytes) / Double(max(progress.totalBytes, 1)) * 100, speed / 1000)
            }
            if let failure = progress.failure { errorText = failure }
        }
    }
}

// MARK: - Superficie de vídeo

private struct VLCSurface: NSViewRepresentable {
    let player: VLCMediaPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        player.drawable = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

// MARK: - Pantalla del reproductor

struct MKVPlayerView: View {
    @ObservedObject var model: MKVPlayerModel
    let title: String
    /// Vista extra en la barra superior (p. ej. el selector Acelerado/Directo).
    var accessory: AnyView?

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing = false
    @State private var scrubValue = 0.0

    var body: some View {
        ZStack {
            Color.black
            VLCSurface(player: model.player)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.togglePlay() }

            if model.isBuffering {
                ProgressView().controlSize(.large)
            }
            if let error = model.errorText {
                Text(error)
                    .font(.callout)
                    .padding(12)
                    .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .opacity(controlsVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        }
        .ignoresSafeArea()
        .onContinuousHover { phase in
            if case .active = phase { showControls() }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { model.togglePlay(); return .handled }
        .onKeyPress(.leftArrow) { model.skip(seconds: -10); return .handled }
        .onKeyPress(.rightArrow) { model.skip(seconds: 10); return .handled }
    }

    private var topBar: some View {
        HStack {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glass(in: Capsule())
            Spacer()
            if let status = model.statusText {
                Text(status)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glass(in: Capsule())
            }
            if let accessory { accessory }
        }
        .padding(.top, 14)
        .padding(.horizontal, 90) // deja libres los botones de la ventana
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 20)
            }
            .buttonStyle(.plain)

            Text(format(scrubbing ? scrubValue : model.currentTime))
                .font(.subheadline.monospacedDigit())

            scrubber

            Text(format(model.duration))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)

            if !model.qualities.isEmpty { qualityMenu }
            trackMenu(systemImage: "speaker.wave.2", tracks: model.audioTracks,
                      selection: model.selectedAudio, action: model.selectAudio)
            trackMenu(systemImage: "captions.bubble", tracks: model.subtitleTracks,
                      selection: model.selectedSubtitle, action: model.selectSubtitle)
        }
        .font(.title3)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .glass(in: Capsule())
        .frame(maxWidth: 900)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    /// Barra de posición; la parte todavía sin descomprimir se ve apagada y no se puede alcanzar.
    private var scrubber: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = model.duration > 0 ? (scrubbing ? scrubValue : model.currentTime) / model.duration : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(.white.opacity(0.3))
                    .frame(width: width * (model.availableFraction ?? 1))
                Capsule().fill(.white)
                    .frame(width: max(0, width * min(max(fraction, 0), 1)))
            }
            .frame(height: 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    scrubbing = true
                    scrubValue = min(max(value.location.x / max(width, 1), 0), 1) * model.duration
                }
                .onEnded { value in
                    model.seek(to: min(max(value.location.x / max(width, 1), 0), 1) * model.duration)
                    scrubbing = false
                })
        }
        .frame(height: 24)
    }

    private var qualityMenu: some View {
        Menu {
            ForEach(model.qualities) { option in
                Button {
                    model.choose(quality: option)
                } label: {
                    if option.id == model.selectedQuality { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func trackMenu(systemImage: String, tracks: [MKVPlayerModel.TrackOption], selection: Int32,
                           action: @escaping (Int32) -> Void) -> some View {
        Menu {
            ForEach(tracks) { track in
                Button {
                    action(track.id)
                } label: {
                    if track.id == selection { Label(track.name, systemImage: "checkmark") } else { Text(track.name) }
                }
            }
        } label: {
            Image(systemName: systemImage)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(tracks.isEmpty)
    }

    private func format(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private func showControls() {
        controlsVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled, model.isPlaying { controlsVisible = false }
        }
    }
}

// MARK: - Reproducción de un RAR de MediaFire

/// Abre el RAR (descarga → descifra → descomprime) y reproduce el MKV en cuanto hay datos.
struct RARPlayerView: View {
    let target: PlaybackTarget
    let pageURL: URL

    @AppStorage(RARSettings.passwordKey) private var password = RARSettings.defaultPassword
    @StateObject private var model = MKVPlayerModel()
    @State private var server: RARStreamServer?
    @State private var failure: String?

    var body: some View {
        ZStack {
            Color.black
            if let failure {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text(failure).font(.headline).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding(24)
            } else if server == nil {
                ProgressView("Abriendo el RAR de MediaFire…")
            } else {
                MKVPlayerView(model: model, title: target.title)
            }
        }
        .ignoresSafeArea()
        .task { await start() }
        .onDisappear {
            model.stop()
            server?.stop()
            server = nil
        }
    }

    private func start() async {
        do {
            let opened = try await RARStreamServer.start(mediaFirePage: pageURL, password: password)
            server = opened
            let stream = opened.stream
            model.sourceProgress = { stream.progress }
            model.play(url: opened.url)
        } catch RARError.wrongPassword {
            failure = "La contraseña del RAR no es correcta.\nCámbiala en Ajustes (⌘,)."
        } catch {
            failure = "No se pudo abrir el RAR: \(error.localizedDescription)"
        }
    }
}

/// Stream normal (con el proxy local) reproducido en VLC, para quien prefiera VLC a todo.
struct VLCStreamPlayerView: View {
    let embedURL: URL
    var target: PlaybackTarget?
    @Binding var mode: PlaybackMode

    @StateObject private var model = MKVPlayerModel()
    @State private var proxy: StreamProxy?
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                VideoWebView(url: embedURL)
            } else if proxy == nil {
                ZStack {
                    Color.black
                    ProgressView("Preparando reproductor…")
                }
            } else {
                MKVPlayerView(model: model, title: "", accessory: AnyView(ModeMenu(mode: $mode)))
            }
        }
        .ignoresSafeArea()
        .task { await start() }
        .onDisappear {
            model.stop()
            let proxy = self.proxy
            self.proxy = nil
            Task { await proxy?.stop() }
        }
    }

    private func start() async {
        do {
            let stream = try await StreamResolver.resolve(from: embedURL)
            let proxy = try await StreamProxy.start(masterURL: stream.masterURL, subtitles: stream.subtitles)
            self.proxy = proxy
            model.setQualities(proxy.qualities)
            model.qualityURLProvider = { option in await proxy.masterURL(quality: option.variant) }
            model.statusProvider = { time in
                let status = await proxy.status(at: time)
                return status.isComplete ? "Todo descargado" : "Buffer \(Int(status.bufferedAhead)) s · \(Int(status.cachedFraction * 100)) %"
            }
            let reporter = WatchProgressReporter(target: target)
            model.progress = reporter
            model.play(url: await proxy.masterURL(quality: nil), startAt: reporter?.resumePosition)
        } catch {
            failed = true
        }
    }
}

/// Ajustes de reproducción de macOS (⌘,): VLC y contraseña de los RAR.
struct PlayerSettingsView: View {
    @AppStorage(RARSettings.passwordKey) private var password = RARSettings.defaultPassword
    @AppStorage(PlaybackSettings.preferVLCKey) private var preferVLC = false

    var body: some View {
        Form {
            Section("Reproductor") {
                Toggle("Usar VLC para todo", isOn: $preferVLC)
                Text("Por defecto se usa el reproductor nativo y VLC solo cuando hace falta (archivos MKV, como los RAR de MediaFire).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("RAR de MediaFire") {
                SecureField("Contraseña", text: $password)
                Text("Por defecto: \(RARSettings.defaultPassword).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding(.vertical, 8)
    }
}
#endif
