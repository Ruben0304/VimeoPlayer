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

    /// Cuánto se desplaza a la derecha un ítem cuando el cursor pasa por encima.
    var hoverShiftX: CGFloat = 10
    var hoverSpringResponse: Double = 0.28
    var hoverSpringDamping: Double = 0.75

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

/// Navegación vertical completamente personalizada — sin `NavigationSplitView`,
/// sin `List`, sin estilos del sistema. Flota como una capa translúcida sobre
/// el contenido (estilo overlay cinematográfico de streaming). Cada fila
/// reacciona a su propio hover desplazándose levemente hacia la derecha.
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

            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityLabel(appName)
        }
        .padding(.horizontal, config.horizontalInset)
        .padding(.top, config.topInset)
        .padding(.bottom, 30)
    }

    private var navigationZone: some View {
        VStack(alignment: .leading, spacing: config.itemSpacing) {
            ForEach(items) { item in
                StreamingSidebarRow(
                    item: item,
                    isSelected: item.id == selectedID,
                    isFocused: focusedID == item.id,
                    config: config,
                    reduceMotion: reduceMotion,
                    action: { onSelect(item) }
                )
                .focused($focusedID, equals: item.id)
            }
        }
        .padding(.horizontal, config.horizontalInset)
        .onKeyPress(.upArrow) { moveFocus(by: -1); return .handled }
        .onKeyPress(.downArrow) { moveFocus(by: 1); return .handled }
        .onKeyPress(.return) { activateFocused(); return .handled }
        .onKeyPress(.space) { activateFocused(); return .handled }
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
/// una píldora de fondo); al pasar el cursor por encima, la fila se desplaza
/// levemente hacia la derecha.
private struct StreamingSidebarRow: View {
    let item: SidebarItemModel
    let isSelected: Bool
    let isFocused: Bool
    let config: SidebarConfiguration
    let reduceMotion: Bool
    let action: () -> Void

    @State private var hovering = false

    private var weight: Font.Weight {
        if isSelected { return .bold }
        return hovering ? .semibold : .medium
    }
    private var opacity: Double {
        if isSelected { return config.selectedOpacity }
        if hovering || isFocused { return config.emphasizedOpacity }
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
        .overlay(alignment: .leading) {
            if isFocused {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(.white.opacity(0.3), lineWidth: 1)
                    .padding(.horizontal, -6)
                    .padding(.vertical, -2)
            }
        }
        .offset(x: !reduceMotion && hovering ? config.hoverShiftX : 0)
        .animation(reduceMotion ? nil : .spring(response: config.hoverSpringResponse, dampingFraction: config.hoverSpringDamping), value: hovering)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel(item.title)
    }
}
