// Siri AI tool intents, and the run entity Siri can refer to.
//
// The APIs used here (the `@AppIntent(.tool)` trait, `@AppEntity(.generable)`, and the
// `authenticationPolicy` argument on an entity property) are part of the Siri AI Developer
// Preview and ship with the iOS 27.3 SDK. Building this file needs Xcode 27.3 or later, so it
// sits behind a compilation condition and is off by default: the rest of the app keeps building
// with the current toolchain. To turn it on, add HANDSY_SIRI_AI to SWIFT_ACTIVE_COMPILATION_CONDITIONS
// for the IPhoneAgent target and build with Xcode 27.3.
//
// Nothing here talks to a model on its own: each intent goes through the same AgentRequests /
// AgentControl entry points the Shortcuts actions and the Live Activity buttons already use.

import Foundation

#if HANDSY_SIRI_AI
import AppIntents

// MARK: - A recorded run

/// One recorded run: what the Runs list shows and what the review screen replays.
/// The task sentence and the last step describe what the person did on their phone, so Siri asks
/// for device authentication before reading them out.
@available(iOS 27.3, *)
struct HandsyRunEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Run"
    static let defaultQuery = HandsyRunQuery()

    let id: String  // the run folder name, yyyyMMdd-HHmmss

    @Property(title: "Task",
              description: "The sentence the person asked for, for example finding cafés in Google Maps.",
              authenticationPolicy: .requiresLocalDeviceAuthentication)
    var task: String

    @Property(title: "Last step",
              description: "What the run did last, in a few words.",
              authenticationPolicy: .requiresLocalDeviceAuthentication)
    var lastStep: String

    @Property(title: "Finished",
              description: "Whether the run reached the end without stopping early.")
    var finished: Bool

    init(_ run: Run) {
        id = run.id
        task = run.task
        lastStep = run.steps.last.map { StepText.line($0.action) } ?? ""
        finished = run.outcome == .done
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(task.isEmpty ? id : task)")
    }
}

/// Finds a run from what the person says, newest first.
@available(iOS 27.3, *)
struct HandsyRunQuery: EntityStringQuery {
    func entities(for identifiers: [HandsyRunEntity.ID]) async throws -> [HandsyRunEntity] {
        await Self.recent().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [HandsyRunEntity] {
        let all = await Self.recent()
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return all }
        return all.filter { $0.task.localizedCaseInsensitiveContains(needle) }
    }

    func suggestedEntities() async throws -> [HandsyRunEntity] { await Self.recent() }

    /// Text only, so Siri can read what is on screen without fetching the runs themselves.
    func displayRepresentations(for identifiers: [HandsyRunEntity.ID],
                               requestedComponents: DisplayRepresentation.Components = .text)
        async throws -> [HandsyRunEntity.ID: DisplayRepresentation] {
        var result: [HandsyRunEntity.ID: DisplayRepresentation] = [:]
        for run in await Self.recent() where identifiers.contains(run.id) {
            result[run.id] = run.displayRepresentation
        }
        return result
    }

    /// RunStore and TraceStore are main-actor types, so the folder list is read there.
    private static func recent() async -> [HandsyRunEntity] {
        await MainActor.run {
            let model = AppModel.shared
            model.runs.reload()
            // Demonstrations are recordings, not runs the agent performed.
            return model.runs.runs.filter { !$0.id.hasPrefix("rec-") }.map(HandsyRunEntity.init)
        }
    }
}

// MARK: - The sentence Siri fills in

/// What the person asked for, as Siri's model understood it. A transient, generable entity: the
/// model fills the property from the request instead of asking the app to look anything up.
@available(iOS 27.3, *)
@AppEntity(.generable)
struct HandsyTaskRequest: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Task Request"

    @Property(title: "Request",
              description: "One sentence, in the person's own words, saying what to do on the iPhone and in which app.")
    var sentence: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(sentence)")
    }

    init() { sentence = "" }
    init(sentence: String) { self.sentence = sentence }
}

// MARK: - Tools

/// Starts a run from one sentence.
@available(iOS 27.3, *)
@AppIntent(.tool)
struct RunHandsyTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Run a Task on This iPhone"
    static let description = IntentDescription(
        "Starts a run that operates this iPhone: it looks at the screen, then taps, swipes and types to carry out one task.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Request",
               description: "One sentence saying what to do, for example finding cafés nearby in Google Maps.")
    var request: HandsyTaskRequest

    init() {}
    init(request: HandsyTaskRequest) { self.request = request }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Ask early, before a run is under way: in a store build the network layer refuses every
        // request for a model host the person has not agreed to, so without this check the run
        // would start and then fail mid-way. Siri says where to fix it instead.
        guard AIConsent.granted(AppModel.shared.settings.baseURL) else {
            return .result(dialog: "Open \(AppName.current) and allow sending screenshots and your task to this model, then ask again.")
        }
        let line = await AgentRequests.handle?(.runTask(request.sentence)) ?? AgentRequests.unavailable
        return .result(dialog: "\(line)")
    }
}

/// Stops the run in progress and lets go of the screen.
@available(iOS 27.3, *)
@AppIntent(.tool)
struct StopHandsyRunIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop the Run"
    static let description = IntentDescription("Stops the run in progress and lets go of the screen.")
    // Stopping is the safe way out and takes nothing away, so it stays allowed while the phone is
    // locked: `.requiresLocalDeviceAuthentication` would demand an unlock first.
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // `stop()` cancels the run's job, so `running` turns false just after it returns: read the
        // state before stopping rather than racing it.
        let model = AppModel.shared
        guard model.agent.running || model.startingAgent else {
            return .result(dialog: "Nothing is running.")
        }
        await AgentControl.handle?(.stop)
        return .result(dialog: "Stopped.")
    }
}

/// Whether the board, Screen Mirroring and the model are ready, and what the run is doing.
@available(iOS 27.3, *)
@AppIntent(.tool)
struct HandsyRunStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Check the Run"
    static let description = IntentDescription(
        "Tells whether the board, Screen Mirroring, the pointer and the model are ready, and what the current or last run is doing.")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let line = await AgentRequests.handle?(.status) ?? AgentRequests.unavailable
        return .result(dialog: "\(line)")
    }
}

/// Opens a recorded run step by step so the person can see what was done.
@available(iOS 27.3, *)
@AppIntent(.tool)
struct ReplayHandsyRunIntent: AppIntent {
    static let title: LocalizedStringResource = "Replay a Run"
    static let description = IntentDescription(
        "Opens a recorded run in the app so the person can go through its steps and screens.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Run", description: "The run to open.")
    var run: HandsyRunEntity

    init() {}
    init(run: HandsyRunEntity) { self.run = run }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let line = await AgentRequests.handle?(.openRun(run.id)) ?? AgentRequests.unavailable
        return .result(dialog: "\(line)")
    }
}
#endif
