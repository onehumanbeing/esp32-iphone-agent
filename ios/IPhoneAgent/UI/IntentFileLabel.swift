import SwiftUI

/// A .intent row: the first intent's icon, color and name ("+2" and a stacked icon when the file holds more), read in the background
/// (a file with screenshots can be 25 MB). Until then, and for a file that does not read, the plain file label.
struct IntentFileLabel: View {
    let entry: AgentFileEntry
    let file: URL
    @State private var first: IntentArchive.Item?
    @State private var second: IntentArchive.Item?
    @State private var more = 0

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.xs) {
                    Text(verbatim: first?.name ?? entry.title).foregroundStyle(.primary).lineLimit(1)
                    if more > 0 { Text(verbatim: "+\(more)").foregroundStyle(.secondary).monospacedDigit() }
                }
                Text(verbatim: entry.detail).font(.footnote).foregroundStyle(.secondary)
            }
        } icon: {
            ZStack {
                if let second {  // several intents: the next one peeks out behind, like a stack of cards
                    tile(second, size: 26).offset(x: 7, y: -6)
                }
                tile(first, size: 28).offset(x: -3, y: 3)
            }
            .frame(width: 34, height: 34)
        }
        .task(id: file) { await load() }
    }

    private func load() async {
        let url = file
        let items = await Task.detached(priority: .utility) {
            (try? Data(contentsOf: url)).flatMap { try? IntentArchive.decode($0) } ?? []
        }.value
        first = items.first
        second = items.count > 1 ? items[1] : nil
        more = max(items.count - 1, 0)
    }

    private func tile(_ item: IntentArchive.Item?, size: CGFloat) -> some View {
        Image(systemName: item?.icon ?? "bolt.fill")
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size / 4, style: .continuous)
                .fill(item == nil ? Color.orange : IntentTint.color(item?.color))
                .shadow(color: .black.opacity(0.15), radius: 1, y: 1))
    }
}
