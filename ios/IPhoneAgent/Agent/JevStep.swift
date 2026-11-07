import Foundation

/// The actor prompt parts Jev needs, cut out the way the gateway does (handsy_trial/jev.py step_input). The
/// screen tree listing after the last blank line is not part of them.
struct JevStepInput: Equatable {
    let goal: String, plan: String, history: String?
    let image: Data

    static func parse(_ text: String, image: Data?) -> JevStepInput? {
        guard let image, image.starts(with: [0xff, 0xd8]),
              let goal = first(#"Goal:\s*(.*)"#, text), !goal.isEmpty,
              let plan = first(#"\n\nPlan:\n(.*?)\n\nRecent actions:\n"#, text, dotAll: true), !plan.isEmpty
        else { return nil }
        let history = first(#"\n\nRecent actions:\n(.*?)(?:\n\n|$)"#, text, dotAll: true)
        return JevStepInput(goal: String(goal.prefix(2000)), plan: String(plan.prefix(4000)),
                            history: history.map { String($0.prefix(4000)) }, image: image)
    }

    private static func first(_ pattern: String, _ text: String, dotAll: Bool = false) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: dotAll ? [.dotMatchesLineSeparators] : []),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return text[r].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Jev's answer for one step: a DO line when it is sure (accept), else a reason ("unsure", "unavailable", …).
struct JevAnswer: Decodable, Equatable {
    var accept = false
    var `do`: String?
    var step_text: String?
    var prob: Double?
    var reason: String?

    /// Jev moves; it never ends a run (a "done" goes to the model, which alone decides the goal is reached).
    var taken: Bool { accept && !(self.do ?? "").isEmpty && !ends }
    var ends: Bool { (self.do ?? "").lowercased().hasPrefix("done") }
}

@MainActor protocol JevStepping: AnyObject {
    func step(_ input: JevStepInput) async throws -> JevAnswer
}

/// Own-model runs: the app asks Jev's server itself, with a ticket from the free line's server (Trial).
@MainActor final class JevStepClient: JevStepping {
    static let timeout = 2.5  // the gateway allows 1.5 s from Hong Kong; a phone adds its own round trip
    private let url: URL?
    private let ticket: () async throws -> String
    private let runID = UUID().uuidString.lowercased()
    private let session: URLSession

    init(url: URL? = URL(string: Trial.origin + "/trial/jev/step"), session: URLSession? = nil,
         ticket: @escaping () async throws -> String = { try await Trial.shared.jevTicket() }) {
        self.url = url
        self.ticket = ticket
        self.session = session ?? {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = Self.timeout
            config.timeoutIntervalForResource = Self.timeout
            return URLSession(configuration: config)
        }()
    }

    func step(_ input: JevStepInput) async throws -> JevAnswer {
        guard let url else { throw TrialError.unavailable }
        var body: [String: Any] = [
            "ticket": try await ticket(), "request_id": UUID().uuidString.lowercased(), "run_id": runID,
            "goal": input.goal, "plan": input.plan, "image": "data:image/jpeg;base64," + input.image.base64EncodedString(),
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        ]
        if let history = input.history { body["history"] = history }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw LLMError(message: "Jev: HTTP \(code)", status: code) }
        return try JSONDecoder().decode(JevAnswer.self, from: data)
    }
}

/// The actor for own-model runs with Jev on: the deciders' order and switches (Deciders.Mode) around the
/// user's model. A step Jev takes comes back as THINK / DO from "handsy-jev", like on the free line, so the
/// run marks it. Each decider has a Breaker: one that keeps failing is skipped for a while, then probed.
@MainActor final class JevDeciderModel: ChatModel, ModelProgressReporting {
    let inner: ChatModel
    let jev: JevStepping
    let mode: Deciders.Mode
    let race: Bool
    let jevBreaker = Breaker("jev"), modelBreaker = Breaker("model")
    var model: String { inner.model }
    var onProgress: ((ModelResponseProgress) -> Void)? {
        get { (inner as? ModelProgressReporting)?.onProgress }
        set { (inner as? ModelProgressReporting)?.onProgress = newValue }
    }

    static let unsure = "THINK: Jev - not sure about this step\nDO: fail Jev is not sure about this step"

    init(inner: ChatModel, jev: JevStepping, mode: Deciders.Mode, race: Bool) {
        self.inner = inner
        self.jev = jev
        self.mode = mode
        self.race = race
    }

    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        let started = now()
        func model() async throws -> ChatResult {
            try await inner.chat(system: system, text: text, image: image, maxTokens: maxTokens, temperature: temperature)
        }
        guard let input = JevStepInput.parse(text, image: image) else {  // not a step prompt (or no JPEG)
            return mode == .jevOnly ? jevReply(nil, since: started) : try await model()
        }
        switch mode {
        case .modelOnly:
            return try await model()
        case .jevOnly:  // no fallback to skip to, so no breaker either
            return jevReply(await askJev(input, breaker: false), since: started)
        case .jevFirst:
            if race, !jevBreaker.isOpen { return try await raced(input, model, since: started) }
            if let answer = await askJev(input) { return jevReply(answer, since: started) }
            return try await model()
        case .modelFirst:
            if modelBreaker.allow() {
                do {
                    let reply = try await model()
                    modelBreaker.record(ok: true)
                    return reply
                } catch {
                    if Task.isCancelled { modelBreaker.release(); throw error }
                    modelBreaker.record(ok: false)
                    if let answer = await askJev(input) { return jevReply(answer, since: started) }
                    throw error
                }
            }
            if let answer = await askJev(input) { return jevReply(answer, since: started) }  // the model is out
            let reply = try await model()
            modelBreaker.record(ok: true)
            return reply
        }
    }

    /// Jev and the model at once: Jev's sure answer wins and cancels the model's request.
    private func raced(_ input: JevStepInput, _ model: @escaping () async throws -> ChatResult,
                       since started: Double) async throws -> ChatResult {
        enum Outcome { case jev(JevAnswer?), model(Result<ChatResult, Error>) }
        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask { await .jev(self.askJev(input)) }
            group.addTask {
                do { return .model(.success(try await model())) } catch { return .model(.failure(error)) }
            }
            var modelResult: Result<ChatResult, Error>?
            var jevDone = false
            while let next = try await group.next() {
                switch next {
                case .jev(let answer):
                    jevDone = true
                    if let answer {
                        group.cancelAll()
                        return jevReply(answer, since: started)
                    }
                    if let modelResult { return try modelResult.get() }
                case .model(let result):
                    modelResult = result
                    if jevDone { return try result.get() }
                }
            }
            throw CancellationError()
        }
    }

    /// Jev's answer when it takes the step; nil when it is unsure, out or cancelled.
    private func askJev(_ input: JevStepInput, breaker: Bool = true) async -> JevAnswer? {
        if breaker, !jevBreaker.allow() { return nil }
        do {
            let answer = try await jev.step(input)
            if answer.reason == "unavailable" {  // its own upstream is down: a failure, not an answer
                if breaker { jevBreaker.record(ok: false) }
                return nil
            }
            if breaker { jevBreaker.record(ok: true) }
            if !answer.taken { DebugLog.write("jev: left the step (\(answer.reason ?? "unsure"))") }
            return answer.taken ? answer : nil
        } catch {
            if breaker { Task.isCancelled ? jevBreaker.release() : jevBreaker.record(ok: false) }
            if !Task.isCancelled { DebugLog.write("jev: step failed: \(error.localizedDescription)") }
            return nil
        }
    }

    private func jevReply(_ answer: JevAnswer?, since started: Double) -> ChatResult {
        let text = answer.map { "THINK: Jev - \(String(($0.step_text ?? "").prefix(300)))\nDO: \($0.do ?? "")" } ?? Self.unsure
        return ChatResult(text: text, firstToken: nil, total: now() - started, finishReason: "stop", servedModel: "handsy-jev")
    }
}
