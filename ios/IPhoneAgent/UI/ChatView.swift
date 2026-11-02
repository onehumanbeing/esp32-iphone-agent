import SwiftUI

/// The current chat on the Agent tab: each finished run is one turn (your words on the right, the result on the
/// left). The next task sees these turns, so "now do the second one too" or "continue" work. You talk between
/// runs only: while a run is going, this app pauses it whenever it is in front.
struct ChatSection: View {
    @ObservedObject var threads: ThreadStore
    var open: (String) -> Void  // a run's review

    var body: some View {
        if !threads.current.turns.isEmpty {
            Section {
                ForEach(threads.current.turns) { turn in
                    VStack(alignment: .leading, spacing: Space.s) {
                        HStack {
                            Spacer(minLength: 40)
                            Text(verbatim: turn.ask)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        Button { open(turn.run) } label: { reply(turn) }.buttonStyle(.plain)
                    }
                    .listRowSeparator(.hidden)
                }
            } header: {
                HStack {
                    Text("Chat")
                    Spacer()
                    Button { threads.newChat(); Haptics.tick() } label: {
                        Label("New chat", systemImage: "square.and.pencil").font(.footnote.weight(.semibold)).textCase(nil)
                    }
                }
            }
        }
    }

    private func reply(_ turn: ChatTurn) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(verbatim: turn.answer.isEmpty ? turn.outcome : turn.answer).lineLimit(4)
            } icon: {
                Image(systemName: StepText.symbol(turn.outcome == "failed" ? "fail" : turn.outcome))
            }
            if !turn.items.isEmpty {
                DisclosureGroup {
                    Text(verbatim: turn.items.joined(separator: "\n")).font(.footnote).textSelection(.enabled)
                } label: {
                    Text("\(turn.items.count) items collected").font(.footnote)
                }
            }
            if !turn.summary.isEmpty {
                Text("Say “continue” to go on from here.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
