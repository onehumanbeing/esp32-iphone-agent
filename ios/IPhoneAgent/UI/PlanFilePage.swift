import MarkdownUI
import SwiftUI

/// A saved plan in Files › Plans (PlanFile): which intent it is for, whether the next run uses it, and the plan,
/// editable in place. Only the plan is edited; the header the app reads stays as it is.
struct PlanFilePage: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var cache: PlanCache
    let file: URL
    let relative: String
    let sandbox: FileSandbox
    @State private var plan: PlanFile?
    @State private var draft = ""
    @State private var editing = false
    @State private var saveFailed = false

    init(app: AppModel, file: URL, relative: String, sandbox: FileSandbox) {
        self.app = app
        cache = app.planCache
        self.file = file
        self.relative = relative
        self.sandbox = sandbox
    }

    var body: some View {
        Group {
            if let plan {
                List {
                    header(plan)
                    Section("Plan") {
                        if editing {
                            TextEditor(text: $draft).frame(minHeight: 280).font(.body)
                        } else {
                            Markdown(plan.plan).textSelection(.enabled)
                        }
                    }
                }
            } else {
                MarkdownFilePage(file: file, relative: relative, sandbox: sandbox)  // not a plan the app can read
            }
        }
        .navigationTitle(Text(verbatim: plan?.name.isEmpty == false ? plan!.name : file.deletingPathExtension().lastPathComponent))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let plan, !plan.newer {
                ToolbarItem(placement: .primaryAction) {
                    if editing {
                        Button("Done", action: save).bold()
                    } else {
                        Button("Edit", systemImage: "pencil") { draft = plan.plan; editing = true }
                    }
                }
            }
        }
        .deletable(relative, in: sandbox)
        .onAppear(perform: load)
        .onDisappear { cache.reload() }
        .alert("Couldn't save", isPresented: $saveFailed) {}
    }

    @ViewBuilder private func header(_ plan: PlanFile) -> some View {
        let intent = app.intents.items.first { $0.id == plan.intent }
        Section {
            HStack(spacing: Space.m) {
                Image(systemName: intent?.symbol ?? "questionmark")
                    .font(.title3).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(IntentTint.color(intent?.color), in: .rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: intent?.name ?? plan.name).font(.headline)
                    Text("Saved \(plan.saved.formatted(.relative(presentation: .named)))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Label(status(plan, intent), systemImage: used(intent) ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(used(intent) ? Color.green : Color.orange)
        } footer: {
            Text(plan.edited
                 ? "You edited this plan, so the app keeps it as it is. It ends when the intent's instruction changes or you delete this file."
                 : "The app wrote this plan from a run that worked. Edit it to keep your version; delete it to plan afresh.")
        }
    }

    private func used(_ intent: SavedTask?) -> Bool { intent.flatMap { cache.entry(for: $0) } != nil }

    private func status(_ plan: PlanFile, _ intent: SavedTask?) -> LocalizedStringKey {
        guard let intent else { return "Its intent is gone" }
        if used(intent) { return "The next run starts from this plan" }
        if plan.key != PlanCache.key(intent) { return "The instruction changed: not used" }
        return "Older than 7 days: not used"
    }

    private func load() {
        plan = (try? String(contentsOf: file, encoding: .utf8)).flatMap(PlanFile.parse)
    }

    private func save() {
        guard cache.update(file, plan: draft) else { saveFailed = true; return }
        editing = false
        load()
    }
}
