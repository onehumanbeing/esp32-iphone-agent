import AppIntents
import SwiftUI
import WidgetKit

// iOS 16 support for the widget extension (iPhone 8 and X stop at iOS 16). iOS 17+ runs exactly what it ran before.

/// `Button(intent:)` (iOS 17: runs the intent in place). Widgets and Live Activities on iOS 16 can't run code, so
/// there the button opens the app at `fallback` (the run, or the quick task sheet).
struct IntentButton<Intent: AppIntent, Content: View>: View {
    let intent: Intent
    let fallback: URL
    @ViewBuilder let label: () -> Content

    var body: some View {
        if #available(iOS 17.0, *) {
            Button(intent: intent, label: label)
        } else {
            Link(destination: fallback, label: label)
        }
    }
}

extension View {
    /// The widget's background (`containerBackground`, iOS 17). iOS 16 draws the system background and adds no
    /// margins of its own, so Home Screen widgets get the standard padding instead (Lock Screen ones none).
    func widgetBackground() -> some View { modifier(WidgetBackground()) }
}

private struct WidgetBackground: ViewModifier {
    @Environment(\.widgetFamily) private var family

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.containerBackground(.fill.tertiary, for: .widget)
        } else if family == .systemSmall || family == .systemMedium {
            content.padding()
        } else {
            content
        }
    }
}
