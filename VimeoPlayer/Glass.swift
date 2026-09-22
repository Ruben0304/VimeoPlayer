import SwiftUI

/// Liquid Glass en iOS/macOS 26+; material translúcido en versiones anteriores.
extension View {
    @ViewBuilder
    func glass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if interactive {
            glassBase(in: shape, tint: tint, interactive: true).pointerCursor()
        } else {
            glassBase(in: shape, tint: tint, interactive: false)
        }
    }

    @ViewBuilder
    private func glassBase<S: Shape>(in shape: S, tint: Color?, interactive: Bool) -> some View {
        if #available(iOS 26, macOS 26, *) {
            glassEffect(glassStyle(tint: tint, interactive: interactive), in: shape)
        } else if let tint {
            background(tint.opacity(0.9), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}

@available(iOS 26, macOS 26, *)
private func glassStyle(tint: Color?, interactive: Bool) -> Glass {
    var style = Glass.regular
    if let tint { style = style.tint(tint) }
    if interactive { style = style.interactive() }
    return style
}

/// Botón de cápsula estilo Apple TV. `prominent` es el botón principal (blanco).
struct GlassButtonLabel: View {
    let title: String
    let systemImage: String
    var prominent = false
    var fullWidth = false

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(prominent ? Color.black : Color.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .glass(in: Capsule(), tint: prominent ? .white : nil, interactive: true)
            .contentShape(Capsule())
    }
}

/// Botón circular con un símbolo.
struct GlassIconLabel: View {
    let systemImage: String
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .glass(in: Circle(), interactive: true)
            .contentShape(Circle())
    }
}

/// Etiqueta pequeña (géneros, "SUB", etc.).
struct GlassChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glass(in: Capsule())
    }
}

/// Aviso breve que flota abajo y se cierra solo.
struct Toast: Equatable {
    let id = UUID()
    let text: String
    let systemImage: String
}

private struct ToastModifier: ViewModifier {
    @Binding var toast: Toast?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast {
                    Label(toast.text, systemImage: toast.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .glass(in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.35), value: toast)
            .task(id: toast) {
                guard toast != nil else { return }
                try? await Task.sleep(for: .seconds(2.5))
                if !Task.isCancelled { toast = nil }
            }
    }
}

extension View {
    func toast(_ toast: Binding<Toast?>) -> some View {
        modifier(ToastModifier(toast: toast))
    }
}

/// Loader de arranque al estilo HBO Max: anillo con estela en degradado que gira
/// sin parar, con la punta brillante y un halo suave. En tonos rojizos.
struct BrandLoader: View {
    var size: CGFloat = 54
    var lineWidth: CGFloat = 4
    /// Segundos por vuelta.
    private let period = 0.85
    /// Fracción del anillo que ocupa la estela.
    private let arc = 0.8

    private static let tail = Color(red: 0.32, green: 0.0, blue: 0.04)
    private static let mid = Color(red: 0.86, green: 0.06, blue: 0.13)
    private static let head = Color(red: 1.0, green: 0.36, blue: 0.3)

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let turn = t.truncatingRemainder(dividingBy: period) / period
            ring.rotationEffect(.degrees(turn * 360))
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Cargando")
    }

    private var ring: some View {
        Circle()
            .trim(from: 0, to: arc)
            .stroke(
                AngularGradient(
                    stops: [
                        .init(color: Self.tail.opacity(0), location: 0),
                        .init(color: Self.tail, location: 0.3),
                        .init(color: Self.mid, location: 0.75),
                        .init(color: Self.head, location: 1),
                    ],
                    center: .center,
                    startAngle: .zero,
                    endAngle: .degrees(360 * arc)
                ),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .shadow(color: Self.mid.opacity(0.55), radius: lineWidth * 1.5)
            .padding(lineWidth / 2)
    }
}
