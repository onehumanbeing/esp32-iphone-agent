import SwiftUI

/// Share intents as a .esp32intent file, screenshots off unless ticked; one intent can be mailed to us too.
struct IntentExportSheet: View {
    @ObservedObject var app: AppModel
    let intents: [SavedTask]
    @Environment(\.dismiss) private var dismiss
    @State private var screenshots = false
    @State private var file: URL?
    @State private var error: String?

    private var steps: [RecordedStep] { intents.flatMap { $0.steps ?? [] } }
    private var stepCount: Int { steps.count }
    private var screenCount: Int { steps.filter { $0.frame != nil }.count }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(intents) { item in
                        HStack(spacing: Space.m) {
                            IntentSourceGlyph(symbol: item.symbol)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: item.name).lineLimit(1)
                                Text("\(item.steps?.count ?? 0) recorded steps").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Toggle("Include screenshots", isOn: $screenshots).disabled(screenCount == 0)
                } footer: {
                    Text(screenCount == 0 ? "No screenshots to include. Steps without screenshots are hints for the model."
                         : "With screenshots, steps can be tapped again without asking the model. Screenshots can show messages, names or other personal details.")
                }
                Section {
                    if let file {
                        ShareLink(item: file) { Label("Share File", systemImage: "square.and.arrow.up") }
                    } else if let error {
                        Text(verbatim: error).foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                } footer: {
                    Text("Instruction, checklist and \(stepCount) steps. Run history is never included.")
                }
                if intents.count == 1, let item = intents.first {
                    Section {
                        NavigationLink { SendIntentView(app: app, intent: item) } label: {
                            Label("Send to Developer", systemImage: "envelope")
                        }
                    } footer: {
                        Text("Share a useful intent with us by mail. Screenshots are blurred first.")
                    }
                }
            }
            .navigationTitle(intents.count == 1 ? "Export Intent" : "Export Intents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear(perform: prepare)
            .onChange(of: screenshots) { prepare() }
        }
    }

    private func prepare() {
        file = nil
        error = nil
        let items = intents.map { IntentArchive.item($0, screenshots: screenshots) }
        do { file = try IntentArchive.write(items) } catch { self.error = error.localizedDescription }
    }
}
