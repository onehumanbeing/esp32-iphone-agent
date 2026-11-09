import SwiftUI

/// The heart of the model page (onboarding's "Give Me a Brain" and Settings › Model): who decides each step.
/// Two rows, Jev and the large language model: drag a row by its handle to set the order, switch each on or off,
/// tap one for its settings (Jev: Handsy or your own TypeSafe key; the model: provider, key and model). Below,
/// on its own, the switch to ask both at once. On your own model, switching Jev on asks for its consent first.
/// Builds without the free line have no Jev: the caller shows the model fields as they are.
struct DecidersPanel: View {
    @ObservedObject var settings: Settings
    var inForm = false
    @State private var deciders = Deciders.standard(freeLine: false)
    @State private var editingModel = false
    @State private var editingJev = false
    @State private var consentRevision = 0  // JevConsent isn't observable: bumped after the sheet agrees
    @State private var dragging: Decider?
    @State private var dragOffset: CGFloat = 0
    @State private var swapped: CGFloat = 0  // rows moved past while dragging, in points
    @AppStorage(Deciders.raceKey) private var race = true
    @AppStorage(JevConfig.ownKey) private var jevOwnKey = false

    private static let rowHeight: CGFloat = 64
    private var freeLine: Bool { settings.provider == .handsyTrial }

    var body: some View {
        Group {
            if inForm {
                Section { rows } header: { Text("Who decides each step") } footer: { Text(footer) }
                if deciders.mode == .jevFirst { Section { raceRow } footer: { Text(raceFooter) } }
            } else {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("Who decides each step").font(.footnote).foregroundStyle(.secondary)
                        .padding(.horizontal, Space.l)
                    Panel { rows }
                    Text(footer).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, Space.l)
                    if deciders.mode == .jevFirst {
                        Panel { raceRow }.padding(.top, Space.l)
                        Text(raceFooter).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, Space.l)
                    }
                }
            }
        }
        .onAppear { deciders = .load(freeLine: freeLine) }
        .onChange(of: settings.provider) { deciders = .load(freeLine: freeLine) }
        .onChange(of: deciders) { deciders.save(freeLine: freeLine) }
        .sheet(isPresented: $editingModel, onDismiss: reload) { ModelFieldsSheet(settings: settings) }
        .sheet(isPresented: $editingJev, onDismiss: reload) { JevFieldsSheet() }
    }

    @ViewBuilder private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(deciders.order.enumerated()), id: \.element) { index, decider in
                row(decider)
                    .overlay(alignment: .top) { if index > 0 && dragging == nil { Divider() } }
                    .offset(y: dragging == decider ? dragOffset : 0)
                    .zIndex(dragging == decider ? 1 : 0)
                    .animation(dragging == decider ? nil : .snappy, value: deciders.order)
            }
            let pending = pendingConsent
            if pending.model || pending.jev {
                Divider()
                SendConsentCard(settings: settings, model: pending.model, jev: pending.jev) { consentRevision += 1 }
            }
        }
        .coordinateSpace(.named("deciders"))  // on the container: the dragged row itself moves
    }

    private func row(_ decider: Decider) -> some View {
        HStack(spacing: Space.m) {
            Image(systemName: "line.3.horizontal")
                .font(.body).foregroundStyle(.tertiary)
                .frame(width: 32, height: Self.rowHeight)
                .contentShape(.rect)
                .highPriorityGesture(drag(decider))
                .accessibilityLabel("Reorder")
            Image(systemName: decider == .jev ? "bolt" : "brain").frame(width: 24)
            Button { if decider == .jev { editingJev = true } else { editingModel = true } } label: { label(decider) }
                .buttonStyle(.plain)
            Toggle(title(decider), isOn: binding(decider))
                .labelsHidden()
                .tint(Palette.accent)
        }
        .frame(height: Self.rowHeight)
        .background {
            if dragging == decider {
                RoundedRectangle(cornerRadius: 12).fill(Palette.surface).shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                    .padding(.horizontal, -Space.s)
            }
        }
    }

    /// Hold the handle, then move: past half a row, the rows swap; the row keeps following the finger.
    /// The short hold first lets the page's scroll view leave the drag to the row.
    private func drag(_ decider: Decider) -> some Gesture {
        LongPressGesture(minimumDuration: 0.15)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("deciders")))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if dragging == nil { dragging = decider; Haptics.tick() }
                let moved = drag?.translation.height ?? 0
                dragOffset = moved - swapped
                guard let i = deciders.order.firstIndex(of: decider) else { return }
                let j = dragOffset > Self.rowHeight / 2 ? i + 1 : dragOffset < -Self.rowHeight / 2 ? i - 1 : i
                guard j != i, deciders.order.indices.contains(j) else { return }
                deciders.order.swapAt(i, j)
                swapped += CGFloat(j - i) * Self.rowHeight
                dragOffset = moved - swapped
                Haptics.tick()
            }
            .onEnded { _ in
                swapped = 0
                withAnimation(.snappy) { dragOffset = 0; dragging = nil }
            }
    }

    private var raceRow: some View {
        HStack(spacing: Space.m) {
            Image(systemName: "arrow.triangle.branch").frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ask Both at Once")
                Text("Faster, uses more tokens").font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Ask Both at Once", isOn: $race).labelsHidden().tint(Palette.accent)
        }
        .frame(minHeight: Self.rowHeight)
    }

    private var raceFooter: LocalizedStringKey {
        "Jev and the Large Language Model get each step together. When Jev isn't sure, the model's answer is already on the way, so no time is lost. The model also answers the steps Jev takes, so it uses more tokens."
    }

    private func title(_ decider: Decider) -> LocalizedStringKey {
        decider == .jev ? "Jev (decision model)" : "Large Language Model"
    }

    private func label(_ decider: Decider) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title(decider)).foregroundStyle(.primary).lineLimit(1)
            HStack(spacing: Space.xs) {
                Text(verbatim: decider == .jev ? jevName : modelName).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private var jevName: String { jevOwnKey && JevConfig.ownActive ? "TypeSafe · \(JevConfig.model)" : "Handsy" }

    private var modelName: String {
        if freeLine { return ModelProvider.handsyTrial.title }
        guard settings.isConfigured else { return String(localized: "Not set up") }
        return settings.model.isEmpty ? settings.providerName : settings.model
    }

    private func binding(_ decider: Decider) -> Binding<Bool> {
        Binding {
            deciders.isOn(decider)
        } set: { on in
            deciders.set(decider, on: on, freeLine: freeLine)
        }
    }

    private func reload() { deciders = .load(freeLine: freeLine); consentRevision += 1 }

    /// One card asks for every yes still missing (the model's host, Jev once it is on), so a first setup taps once.
    private var pendingConsent: (model: Bool, jev: Bool) {
        _ = consentRevision
        let model = AIConsent.store && settings.isConfigured && !AIConsent.granted(settings.baseURL)
        return (model, deciders.isOn(.jev) && JevConsent.needed(freeLine: freeLine))
    }

    private var footer: LocalizedStringKey {
        switch deciders.mode {
        case .jevFirst: return "Jev takes the plain steps in a fraction of a second and leaves the rest to the Large Language Model. Drag ≡ to change the order."
        case .modelFirst: return "The Large Language Model decides. Jev steps in only when the model doesn't answer. Drag ≡ to change the order."
        case .jevOnly: return "Experimental: only Jev decides. When it isn't sure about a step, the run stops and asks you."
        case .modelOnly: return freeLine ? "Only the Large Language Model decides. On Handsy Free it stays on."
            : "Only your Large Language Model decides. Jev sends each step to its server, so it asks you first."
        }
    }
}
