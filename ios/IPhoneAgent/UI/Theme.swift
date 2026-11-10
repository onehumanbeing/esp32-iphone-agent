import SwiftUI
import UIKit

/// Spacing on the 8 pt grid; colors are the system's semantic colors plus the app's accent (the eyes' glow).
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum Palette {
    static let ink = Color.primary
    static let muted = Color.secondary
    static let accent = Color.accentColor
    static let stop = Color.red
    static let warning = Color.orange
    static let ok = Color.green
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let grouped = Color(uiColor: .systemGroupedBackground)
    static let background = Color(uiColor: .systemBackground)
    static let line = Color(uiColor: .separator)
}

enum Haptics {
    static func start() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func stop() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func tick() { UISelectionFeedbackGenerator().selectionChanged() }
    static func failure() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

/// A short side-to-side shake, e.g. a Start that couldn't go ahead. Bump `shakes` to play it.
struct Shake: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat { get { shakes } set { shakes = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(shakes * .pi * 4), y: 0))
    }
}

/// The line over Home from `AppModel.toast`; it goes away by itself.
struct ToastView: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.footnote.weight(.medium))
            .padding(.horizontal, Space.m).padding(.vertical, Space.s)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(.horizontal, Space.m)
    }
}

/// The screen's main action, pinned above the home indicator (HIG: one prominent button at the bottom).
struct BottomBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: Space.s) { content }
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.m)
            .padding(.bottom, Space.s)
            .padWidth(640)
            .frame(maxWidth: .infinity)
            .background(.bar)
    }
}

extension View {
    /// iPad: at most `width` wide and centred, so a page or a button doesn't stretch across a landscape screen.
    /// An iPhone is never that wide: unchanged.
    @ViewBuilder func padWidth(_ width: CGFloat) -> some View {
        if DeviceKind.isPad { frame(maxWidth: width).frame(maxWidth: .infinity) } else { self }
    }
}

/// Full-width prominent button label: `Button { } label: { BigLabel("Start", "play.fill") }`.
struct BigButton: ButtonStyle {
    var tint: Color = .accentColor
    var ink: Color = .white
    /// The secondary actions next to a screen's one filled button: the same hue, tinted (HIG: one prominent action).
    static let tinted = BigButton(tint: .accentColor.opacity(0.15), ink: .accentColor)
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(enabled ? ink : Color.secondary)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(enabled ? tint : Color(uiColor: .tertiarySystemFill)))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// A centered "nothing here yet" message with the character.
struct EmptyState: View {
    var mood: Mood = .sleeping
    let title: LocalizedStringKey
    var message: LocalizedStringKey?

    var body: some View {
        VStack(spacing: Space.m) {
            PokeableFace(mood: mood).frame(width: 72, height: 80)
            Text(title).font(.headline)
            if let message {
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xl)
    }
}

/// A key/value row for Diagnostics and Settings.
struct ValueRow: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        LabeledContent(title) { Text(verbatim: value).monospacedDigit().foregroundStyle(.secondary) }
    }
}

/// A row icon in a rounded colored square, like Settings.app.
struct SettingsIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color))
    }
}

struct SettingsLabel: View {
    let title: LocalizedStringKey
    let symbol: String
    let color: Color

    var body: some View {
        Label { Text(title) } icon: { SettingsIcon(symbol: symbol, color: color) }
    }
}

extension Double {
    /// "12 s" / "1 min 4 s".
    var durationText: String {
        let f = DateComponentsFormatter()
        f.allowedUnits = self >= 60 ? [.minute, .second] : [.second]
        f.unitsStyle = .abbreviated
        return f.string(from: self) ?? "–"
    }
}
