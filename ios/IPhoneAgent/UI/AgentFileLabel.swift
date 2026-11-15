import SwiftUI

/// The name and size of one file, with its symbol. The row around it is the control.
struct AgentFileLabel: View {
    let entry: AgentFileEntry

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(verbatim: entry.name).foregroundStyle(.primary).lineLimit(1)
                Text(verbatim: entry.detail).font(.footnote).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: entry.symbol).foregroundStyle(entry.tint).frame(width: 28)
        }
    }
}
