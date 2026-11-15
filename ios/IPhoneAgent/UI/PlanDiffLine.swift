import SwiftUI

/// One line of the plan diff. The sign is spoken as well as colored, so the change is clear without color.
struct PlanDiffLine: View {
    let row: TextDiff.Row

    var body: some View {
        Text(verbatim: mark + row.text)
            .font(.footnote.monospaced())
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(Text(verbatim: "\(spoken) \(row.text)"))
            .listRowInsets(EdgeInsets(top: 2, leading: Space.m, bottom: 2, trailing: Space.m))
    }

    private var mark: String {
        switch row.kind {
        case .added: return "+ "
        case .removed: return "− "
        case .same: return "  "
        }
    }

    private var spoken: String {
        switch row.kind {
        case .added: return String(localized: "Added")
        case .removed: return String(localized: "Removed")
        case .same: return String(localized: "Unchanged")
        }
    }

    private var color: Color {
        switch row.kind {
        case .added: return Palette.ok
        case .removed: return Palette.stop
        case .same: return .primary
        }
    }
}
