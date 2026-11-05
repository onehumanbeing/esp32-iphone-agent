import AppIntents
import Foundation

/// A request from Siri, Shortcuts, a widget or a control, handled by the app process (AppModel sets `handle`).
enum AgentRequest {
    case runTask(String), runSaved(UUID?), status, calibrate
    /// Opens a recorded run in the review screen (Siri's "replay" tool).
    case openRun(String)
}

@MainActor enum AgentRequests {
    /// Returns the line to say or show.
    static var handle: ((AgentRequest) async -> String)?
    nonisolated static var unavailable: String { String(localized: "Open ESP32 Agent once, then try again.") }
}

/// A saved intent (My Intents), as Siri and Shortcuts see it.
struct SavedIntentEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Saved Intent"
    static let defaultQuery = SavedIntentQuery()

    let id: UUID
    let name: String
    let symbol: String

    init(_ item: AgentSnapshot.Item) {
        id = item.id
        name = item.name
        symbol = item.symbol
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: symbol))
    }
}

struct SavedIntentQuery: EntityStringQuery {
    private var items: [SavedIntentEntity] { (SharedState.load()?.intents ?? []).map(SavedIntentEntity.init) }

    func entities(for identifiers: [UUID]) async throws -> [SavedIntentEntity] {
        items.filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [SavedIntentEntity] {
        items.filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [SavedIntentEntity] { items }
}

/// Runs a saved intent. A LiveActivityIntent, so it runs in the app process (also from a widget button)
/// and may start the Live Activity from the background.
struct RunSavedIntentIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Run a Saved Intent"
    static let description = IntentDescription("Runs one of your saved intents on ESP32 Agent.")

    @Parameter(title: "Intent") var intent: SavedIntentEntity

    init() {}
    init(intent: SavedIntentEntity) { self.intent = intent }

    static var parameterSummary: some ParameterSummary { Summary("Run \(\.$intent)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let line = await AgentRequests.handle?(.runSaved(intent.id)) ?? AgentRequests.unavailable
        return .result(dialog: "\(line)")
    }
}

/// Runs the intent run last (else the first saved one): the Control Center button.
struct RunLastIntentIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Run Last Intent"
    static let description = IntentDescription("Runs the saved intent you ran last on ESP32 Agent.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let line = await AgentRequests.handle?(.runSaved(nil)) ?? AgentRequests.unavailable
        return .result(dialog: "\(line)")
    }
}
