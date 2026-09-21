import SwiftUI

/// Un ítem de navegación de la sidebar. El dominio (una `SidebarCategory`, un
/// género, etc.) se mapea a esto en el call site — el componente no conoce
/// nada de categorías, películas ni géneros, es puramente presentacional.
struct SidebarItemModel: Identifiable, Equatable {
    let id: String
    let title: String
    var isEnabled: Bool = true
}

/// Todos los valores visuales/de interacción de `StreamingSidebar` centralizados
/// aquí: nada de magic numbers sueltos en la lógica de la vista.
struct SidebarConfiguration {
    /// Ancho fijo de la columna de navegación; la ventana puede cambiar de
    /// tamaño sin que esto se deforme.
    var width: CGFloat = 250
    var horizontalInset: CGFloat = 30
    var itemSpacing: CGFloat = 16
    var titleSize: CGFloat = 16
    var sectionLabelSize: CGFloat = 11

    /// Escala en reposo, sin influencia del cursor.
    var baseScale: CGFloat = 1.0
    /// Escala del ítem exactamente bajo el cursor.
    var maximumScale: CGFloat = 1.16
    /// Distancia (pt) más allá de la cual el cursor deja de influir en un ítem.
    var influenceRadius: CGFloat = 116
    /// Cuánto se desplazan los vecinos para dejarle espacio al ítem magnificado
    /// (0 = nada, 1 = su propio alto).
    var pushFactor: CGFloat = 0.3
    var springResponse: Double = 0.22
    var springDamping: Double = 0.82

    var dimmedOpacity: Double = 0.5
    var emphasizedOpacity: Double = 0.85
    var selectedOpacity: Double = 1.0

    /// Opacidad del scrim oscuro de fondo (a pantalla completa, en `HomeView`)
    /// cuando la sidebar está abierta: flota como un overlay sobre la vista
    /// actual (drawer), no como un panel fijo que reserva espacio en el layout.
    var scrimOpacity: Double = 0.55
    /// Opacidad máxima (junto al borde izquierdo) del degradado negro pegado
    /// a la propia columna; se desvanece a transparente hacia el contenido.
    var localScrimOpacity: Double = 0.92
    var closeButtonSize: CGFloat = 54
    var topInset: CGFloat = SidebarConfiguration.platformTopInset

    static let `default` = SidebarConfiguration()

    private static var platformTopInset: CGFloat {
        #if os(macOS)
        44
        #else
        24
        #endif
    }
}

/// Matemática pura de la magnificación: sin estado ni SwiftUI, fácil de testear.
enum SidebarMagnification {
    /// Curva Hermite (smoothstep): la influencia se mantiene alta cerca del
    /// cursor y se apaga con una transición suave, en vez de decaer a ritmo
    /// constante como una recta — de ahí que el efecto se sienta "de onda".
    private static func smoothstep(_ t: CGFloat) -> CGFloat {
        let clamped = min(max(t, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    /// `influence` en [0, 1]: 1 justo bajo el cursor, decae suavemente hasta 0 en `influenceRadius`.
    static func influence(distance: CGFloat, config: SidebarConfiguration) -> CGFloat {
        guard config.influenceRadius > 0 else { return 0 }
        let normalized = min(abs(distance) / config.influenceRadius, 1)
        return 1 - smoothstep(normalized)
    }

    static func scale(distance: CGFloat, config: SidebarConfiguration) -> CGFloat {
        let influence = influence(distance: distance, config: config)
        return config.baseScale + influence * (config.maximumScale - config.baseScale)
    }

    /// Desplazamiento vertical de un vecino para "dejar espacio" al ítem bajo
    /// el cursor: una campana simétrica, 0 en el propio centro del cursor (no
    /// se mueve a sí mismo) y 0 lejos de él, con el pico a media distancia.
    static func neighborOffset(distance: CGFloat, direction: CGFloat, rowHeight: CGFloat, config: SidebarConfiguration) -> CGFloat {
        guard config.influenceRadius > 0 else { return 0 }
        let normalized = min(abs(distance) / config.influenceRadius, 1)
        let bump = 4 * normalized * (1 - normalized)
        return direction * bump * rowHeight * config.pushFactor
    }
}

private struct RowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private let sidebarCoordinateSpace = "streamingSidebar"

/// Navegación vertical completamente personalizada — sin `NavigationSplitView`,
/// sin `List`, sin estilos del sistema. Flota como una capa translúcida sobre
/// el contenido (estilo overlay cinematográfico de streaming) e implementa un
/// "vertical magnification carousel": la posición Y del cursor controla de
/// forma continua la escala de cada fila, con los vecinos desplazándose
/// levemente para dejarle espacio. No depende de AppKit: el tracking usa
/// `onContinuousHover`, la API nativa de SwiftUI para posición continua de puntero.
struct StreamingSidebar<Footer: View>: View {
    let appName: String
    var sectionLabel: String? = nil
    let items: [SidebarItemModel]
    let selectedID: String?
    var config: SidebarConfiguration = .default
    let onSelect: (SidebarItemModel) -> Void
    /// Cuando se provee, se dibuja un botón "X" junto al logo (como en la
    /// referencia) para poder cerrar la sidebar flotante.
    var onClose: (() -> Void)? = nil
    @ViewBuilder var footer: () -> Footer

    @State private var mouseY: CGFloat?
    @State private var rowFrames: [String: CGRect] = [:]
    @FocusState private var focusedID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let sectionLabel {
                Text(sectionLabel)
                    .font(.system(size: config.sectionLabelSize, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.horizontal, config.horizontalInset)
                    .padding(.bottom, 16)
            }

            navigationZone

            Spacer(minLength: 24)

            footer()
                .padding(.horizontal, config.horizontalInset)
                .padding(.bottom, 24)
        }
        .frame(width: config.width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(localScrim)
        .onKeyPress(.escape) {
            guard let onClose else { return .ignored }
            onClose()
            return .handled
        }
    }

    /// Degradado negro pegado detrás de la propia columna (igual que la
    /// referencia): opaco junto al texto, se desvanece hacia el contenido.
    private var localScrim: some View {
        LinearGradient(
            colors: [.black.opacity(config.localScrimOpacity), .black.opacity(config.localScrimOpacity * 0.55), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let onClose {
                SidebarChromeButton(style: .close, size: config.closeButtonSize, action: onClose)
            }

            Text(appName)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, config.horizontalInset)
        .padding(.top, config.topInset)
        .padding(.bottom, 30)
    }

    /// Solo esta zona participa del tracking de cursor y la magnificación —
    /// el título y el footer permanecen siempre a tamaño fijo.
    private var navigationZone: some View {
        VStack(alignment: .leading, spacing: config.itemSpacing) {
            ForEach(items) { item in
                StreamingSidebarRow(
                    item: item,
                    isSelected: item.id == selectedID,
                    scale: scale(for: item),
                    offsetY: offsetY(for: item),
                    isFocused: focusedID == item.id,
                    config: config,
                    action: { onSelect(item) }
                )
                .focused($focusedID, equals: item.id)
                // El ítem magnificado se dibuja por encima de sus vecinos
                // para que crecer no produzca clipping entre filas.
                .zIndex(scale(for: item))
            }
        }
        .padding(.horizontal, config.horizontalInset)
        .coordinateSpace(name: sidebarCoordinateSpace)
        .onPreferenceChange(RowFramePreferenceKey.self) { rowFrames = $0 }
        .onContinuousHover(coordinateSpace: .named(sidebarCoordinateSpace)) { phase in
            switch phase {
            case .active(let location): mouseY = location.y
            case .ended: mouseY = nil
            }
        }
        .animation(reduceMotion ? nil : .spring(response: config.springResponse, dampingFraction: config.springDamping), value: mouseY)
        .onKeyPress(.upArrow) { moveFocus(by: -1); return .handled }
        .onKeyPress(.downArrow) { moveFocus(by: 1); return .handled }
        .onKeyPress(.return) { activateFocused(); return .handled }
        .onKeyPress(.space) { activateFocused(); return .handled }
    }

    private func scale(for item: SidebarItemModel) -> CGFloat {
        guard !reduceMotion, let mouseY, let frame = rowFrames[item.id] else { return config.baseScale }
        return SidebarMagnification.scale(distance: frame.midY - mouseY, config: config)
    }

    private func offsetY(for item: SidebarItemModel) -> CGFloat {
        guard !reduceMotion, let mouseY, let frame = rowFrames[item.id] else { return 0 }
        let distance = frame.midY - mouseY
        let direction: CGFloat = distance < 0 ? -1 : (distance > 0 ? 1 : 0)
        return SidebarMagnification.neighborOffset(distance: distance, direction: direction, rowHeight: frame.height, config: config)
    }

    private func moveFocus(by delta: Int) {
        let selectable = items.filter { $0.isEnabled }
        guard !selectable.isEmpty else { return }
        guard let currentID = focusedID, let currentIndex = selectable.firstIndex(where: { $0.id == currentID }) else {
            focusedID = delta > 0 ? selectable.first?.id : selectable.last?.id
            return
        }
        let nextIndex = (currentIndex + delta + selectable.count) % selectable.count
        focusedID = selectable[nextIndex].id
    }

    private func activateFocused() {
        guard let focusedID, let item = items.first(where: { $0.id == focusedID }), item.isEnabled else { return }
        onSelect(item)
    }
}

/// Botón de cabecera dibujado a mano (líneas propias, sin SF Symbols ni
/// ningún otro set de iconos): abrir/cerrar la sidebar comparten exactamente
/// el mismo tamaño y el mismo trazo minimalista de la referencia.
struct SidebarChromeButton: View {
    enum Style { case close, menu }

    let style: Style
    var size: CGFloat = 54
    let action: () -> Void

    private var strokeWidth: CGFloat { size * 0.42 }
    private var strokeThickness: CGFloat { 2.2 }

    var body: some View {
        Button(action: action) {
            glyph
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style == .close ? "Cerrar navegación" : "Abrir navegación")
    }

    @ViewBuilder
    private var glyph: some View {
        switch style {
        case .close:
            ZStack {
                Capsule().fill(.white.opacity(0.9))
                    .frame(width: strokeWidth, height: strokeThickness)
                    .rotationEffect(.degrees(45))
                Capsule().fill(.white.opacity(0.9))
                    .frame(width: strokeWidth, height: strokeThickness)
                    .rotationEffect(.degrees(-45))
            }
        case .menu:
            VStack(spacing: strokeWidth * 0.28) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule().fill(.white.opacity(0.9))
                        .frame(width: strokeWidth, height: strokeThickness)
                }
            }
        }
    }
}

extension StreamingSidebar where Footer == EmptyView {
    init(
        appName: String,
        sectionLabel: String? = nil,
        items: [SidebarItemModel],
        selectedID: String?,
        config: SidebarConfiguration = .default,
        onSelect: @escaping (SidebarItemModel) -> Void,
        onClose: (() -> Void)? = nil
    ) {
        self.init(appName: appName, sectionLabel: sectionLabel, items: items, selectedID: selectedID, config: config, onSelect: onSelect, onClose: onClose) {
            EmptyView()
        }
    }
}

/// Una fila: icono + título en un `HStack` propio, sin componentes de lista
/// del sistema. La selección se comunica solo con tipografía/contraste (nunca
/// una píldora de fondo); el tamaño lo controla exclusivamente el cursor.
private struct StreamingSidebarRow: View {
    let item: SidebarItemModel
    let isSelected: Bool
    let scale: CGFloat
    let offsetY: CGFloat
    let isFocused: Bool
    let config: SidebarConfiguration
    let action: () -> Void

    private var isMagnified: Bool { scale > 1.02 }
    private var weight: Font.Weight {
        if isSelected { return .bold }
        return isMagnified ? .semibold : .medium
    }
    private var opacity: Double {
        if isSelected { return config.selectedOpacity }
        if isMagnified || isFocused { return config.emphasizedOpacity }
        return config.dimmedOpacity
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(item.title)
                    .font(.system(size: config.titleSize, weight: weight))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white.opacity(opacity))
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .opacity(item.isEnabled ? 1 : 0.35)
        // El frame se mide AQUÍ, antes de escalar/desplazar, para que el
        // cálculo de distancia use siempre la posición de reposo de la fila
        // y no realimente el resultado con su propia transformación visual.
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: RowFramePreferenceKey.self,
                    value: [item.id: geo.frame(in: .named(sidebarCoordinateSpace))]
                )
            }
        )
        .overlay(alignment: .leading) {
            if isFocused {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(.white.opacity(0.3), lineWidth: 1)
                    .padding(.horizontal, -6)
                    .padding(.vertical, -2)
            }
        }
        .scaleEffect(scale, anchor: .leading)
        .offset(y: offsetY)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel(item.title)
    }
}
