import SwiftUI

/// One intent inside a .intent file: glyph and name (tap to pick it, when the file holds several), the instruction,
/// its checklist, and the recorded steps with the reference screens the file carries.
struct IntentFileItemSection: View {
    let item: IntentArchive.Item
    let screens: [UIImage]
    let saved: Bool
    @Binding var picked: Bool
    var pickable = true  // a file with one intent has nothing to choose between

    var body: some View {
        Section {
            if pickable {
                Button { picked.toggle() } label: { header }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(picked ? .isSelected : [])
            } else {
                header
            }
            Text(verbatim: item.prompt)
            ForEach(item.hints ?? [], id: \.self) { hint in
                Label { Text(verbatim: hint) } icon: { Image(systemName: "checklist") }
                    .font(.subheadline)
            }
            if let steps = item.steps, !steps.isEmpty {
                LabeledContent("Recorded steps", value: steps.count.formatted())
                if !screens.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: Space.s) {
                            ForEach(screens.indices, id: \.self) { i in
                                Image(uiImage: screens[i])
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: 160)
                                    .clipShape(.rect(cornerRadius: 8))
                                    .accessibilityLabel(Text("Step \(i + 1)"))
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: Space.m) {
            Image(systemName: item.icon ?? "bolt.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(IntentTint.color(item.color), in: .rect(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(verbatim: item.name).font(.headline)
                if saved {
                    Text("May already be in your intents").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if pickable {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(picked ? Color.accentColor : Color.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}
