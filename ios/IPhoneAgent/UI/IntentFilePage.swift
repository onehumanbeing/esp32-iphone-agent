import SwiftUI

/// A .intent file in Files: what each intent in it does, and Add for the ones the user picks (all but those that
/// look saved, to start). Files carry no ids, so "already saved" is only a guess: adding one of those asks first.
struct IntentFilePage: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var intents: IntentStore
    let file: URL
    @State private var items: [IntentArchive.Item] = []
    @State private var screens: [[UIImage]] = []  // per item, decoded once
    @State private var picked: Set<Int> = []
    @State private var failure: String?
    @State private var confirming = false

    init(app: AppModel, file: URL) {
        self.app = app
        self.intents = app.intents
        self.file = file
    }

    var body: some View {
        List {
            if let failure {
                Section { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
            }
            ForEach(items.indices, id: \.self) { i in
                IntentFileItemSection(item: items[i], screens: i < screens.count ? screens[i] : [], saved: saved(i),
                                      picked: binding(i), pickable: items.count > 1)
            }
            if !items.isEmpty {
                Section {} footer: { Text("Adds a copy to the Agent tab. This file stays where it is.") }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !items.isEmpty {
                BottomBar {
                    HStack(spacing: Space.s) {
                        if items.count > 1 {
                            Button(action: toggleAll) {
                                Text(picked.count == items.count ? "Deselect All" : "Select All")
                                    .lineLimit(1).padding(.horizontal, Space.m)
                            }
                            .buttonStyle(BigButton.tinted)
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        Button(action: add) { Label(addTitle, systemImage: "plus") }
                            .buttonStyle(BigButton())
                            .disabled(chosen.isEmpty)
                    }
                }
            }
        }
        .navigationTitle(Text(verbatim: file.deletingPathExtension().lastPathComponent))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: file) { Label("Share", systemImage: "square.and.arrow.up") }
            }
        }
        .confirmationDialog("Some of these may already be in your intents.", isPresented: $confirming,
                            titleVisibility: .visible) {
            Button("Add Anyway") { finishAdd() }
        } message: {
            Text("Adding them again makes a second copy.")
        }
        .task(id: file) { load() }
    }

    /// One intent: always the one; several: those picked, in the file's order.
    private var chosen: [Int] { items.count == 1 ? [0] : picked.sorted() }

    private var addTitle: LocalizedStringKey {
        items.count == 1 ? "Add to Intents" : "Add to Intents (\(chosen.count))"
    }

    private func saved(_ i: Int) -> Bool { IntentArchive.looksSaved(items[i], in: intents.items) }

    private func binding(_ i: Int) -> Binding<Bool> {
        Binding(get: { picked.contains(i) }, set: { on in if on { picked.insert(i) } else { picked.remove(i) } })
    }

    private func toggleAll() {
        picked = picked.count == items.count ? [] : Set(items.indices)
    }

    private func add() {
        if chosen.contains(where: saved) { confirming = true } else { finishAdd() }
    }

    private func finishAdd() {
        app.addIntents(chosen.map { items[$0] })
        picked = Set(items.indices.filter { !saved($0) })  // back here later: nothing left picked that is now saved
    }

    private func load() {
        do {
            items = try IntentArchive.decode(try Data(contentsOf: file))
            screens = items.map { item in
                (item.steps ?? []).compactMap { $0.frame.flatMap { Data(base64Encoded: $0) }.flatMap(UIImage.init(data:)) }
            }
            picked = Set(items.indices.filter { !saved($0) })
            failure = items.isEmpty ? String(localized: "No intents in this file.") : nil
        } catch {
            items = []
            failure = error.localizedDescription
        }
    }
}
