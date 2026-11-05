import SwiftUI

/// Home's readiness at a glance: board, mirroring, mouse, pointer and model. A problem chip turns orange;
/// tapping it opens the setup page that fixes it.
struct StatusChips: View {
    @ObservedObject var app: AppModel
    @ObservedObject var board: BoardLink
    @ObservedObject var pointer: Pointer
    @ObservedObject var calibrator: AutoCalibrator

    var body: some View {
        FlowLayout(spacing: Space.s) {
            chip("Board", "cable.connector", ok: board.connected, page: .connect)
            chip("Mirroring", "rectangle.on.rectangle", ok: board.connected && board.status?.ap == "streaming", page: .see)
            chip("Mouse", "cursorarrow", ok: board.connected && board.status?.usb == "ok", page: .act)
            chip(calibrator.busy ? "Calibrating" : "Pointer", "scope", ok: pointer.calibrated, busy: calibrator.busy, page: .act)
            chip(app.settings.provider == .handsyTrial && app.modelOK == false
                 ? (Trial.shared.status == .usedUp ? "Free Runs Used" : "Free Line Busy") : "Model", "brain",  // free line
                 ok: app.modelReady && app.modelOK != false, page: .brain)
        }
        .padding(.horizontal, Space.l)
    }

    private func chip(_ title: LocalizedStringKey, _ symbol: String, ok: Bool, busy: Bool = false,
                      page: SetupPage) -> some View {
        Button {
            Haptics.tick()
            app.setupPage = page
        } label: {
            HStack(spacing: 5) {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: ok ? "checkmark.circle.fill" : symbol)
                        .foregroundStyle(ok ? Palette.ok : Palette.warning)
                }
                Text(title)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(ok ? Color.primary : Palette.warning)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(ok ? Palette.surface : Palette.warning.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(ok ? "Ready" : "Needs setup"))
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: ok)
    }
}

/// Lays children out left to right, wrapping to new lines, each line centered.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for (i, v) in subviews.enumerated() {
            let size = v.sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].items.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width && !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            var r = rows[rows.count - 1]
            r.width += r.items.isEmpty ? size.width : size.width + spacing
            r.height = max(r.height, size.height)
            r.items.append(i)
            rows[rows.count - 1] = r
        }
        return rows
    }
}
