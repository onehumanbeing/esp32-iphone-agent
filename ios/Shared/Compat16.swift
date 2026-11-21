import SwiftUI

// iOS 16 support: iPhone 8 and X stop at iOS 16. Each helper calls the iOS 17/18 API where it exists, so newer
// iPhones run exactly what they ran before; only iOS 16 takes the `else` branch.

extension View {
    /// `onChange(of:initial:_:)` (iOS 17) with the old and the new value. iOS 16: `onChange(of:perform:)`, the old
    /// value captured when the body was built (Apple's own pattern), and `initial` runs it on appear.
    @ViewBuilder
    func onValueChange<V: Equatable>(of value: V, initial: Bool = false,
                                     _ action: @escaping (_ old: V, _ new: V) -> Void) -> some View {
        if #available(iOS 17.0, *) {
            onChange(of: value, initial: initial, action)
        } else {
            onChange(of: value) { [value] new in action(value, new) }
                .onAppear { if initial { action(value, value) } }
        }
    }

    /// `onChange(of:initial:_:)` (iOS 17) without the values.
    func onValueChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping () -> Void) -> some View {
        onValueChange(of: value, initial: initial) { _, _ in action() }
    }

    /// `listSectionSpacing` (iOS 17); iOS 16 keeps the default spacing.
    @ViewBuilder
    func sectionSpacing(_ spacing: CGFloat) -> some View {
        if #available(iOS 17.0, *) { listSectionSpacing(spacing) } else { self }
    }

    /// `contentMargins(_:_:for: .scrollContent)` (iOS 17); iOS 16 keeps the default margins.
    @ViewBuilder
    func scrollContentMargins(_ edges: Edge.Set, _ length: CGFloat) -> some View {
        if #available(iOS 17.0, *) { contentMargins(edges, length, for: .scrollContent) } else { self }
    }

    /// A repeating pulse on an SF Symbol (iOS 17); iOS 16 shows the symbol still.
    @ViewBuilder
    func pulsing(_ active: Bool) -> some View {
        if #available(iOS 17.0, *) { symbolEffect(.pulse, options: .repeating, isActive: active) } else { self }
    }

    /// Names this view's coordinate space (`coordinateSpace(.named(_:))` on iOS 17, `coordinateSpace(name:)` before).
    @ViewBuilder
    func namedCoordinateSpace(_ name: String) -> some View {
        if #available(iOS 17.0, *) { coordinateSpace(.named(name)) } else { coordinateSpace(name: name) }
    }
}

/// `ContentUnavailableView` (iOS 17); iOS 16: the same symbol, title, description and actions, stacked.
struct UnavailableView<Actions: View>: View {
    private let title: Text
    private let systemImage: String
    private let description: Text?
    private let actions: Actions

    init(_ title: LocalizedStringKey, systemImage: String, description: Text? = nil,
         @ViewBuilder actions: () -> Actions) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.description = description
        self.actions = actions()
    }

    var body: some View {
        if #available(iOS 17.0, *) {
            ContentUnavailableView {
                Label { title } icon: { Image(systemName: systemImage) }
            } description: {
                if let description { description }
            } actions: {
                actions
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: systemImage).font(.system(size: 44)).foregroundStyle(.secondary)
                title.font(.title2.bold())
                if let description { description.font(.callout).foregroundStyle(.secondary) }
                actions
            }
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension UnavailableView where Actions == EmptyView {
    init(_ title: LocalizedStringKey, systemImage: String, description: Text? = nil) {
        self.init(title, systemImage: systemImage, description: description) { EmptyView() }
    }
}

/// `ContentUnavailableView.search(text:)` (iOS 17); iOS 16: "No Results" with the search text.
struct EmptySearch: View {
    let text: String

    var body: some View {
        if #available(iOS 17.0, *) {
            ContentUnavailableView.search(text: text)
        } else {
            UnavailableView("No Results", systemImage: "magnifyingglass", description: Text(verbatim: "“\(text)”"))
        }
    }
}
