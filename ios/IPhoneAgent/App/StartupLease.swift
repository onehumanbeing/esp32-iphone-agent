import Foundation

/// The free line's lease for a run, claimed as soon as the line's precheck passed, beside the stream, leaving the app
/// and the first frame, and awaited only before the first model call (Henry 2026-11-27: a start that then fails costs
/// a free run; see Trial.precheck). Nil claim: one's own model, nothing to wait for.
@MainActor final class StartupLease {
    private var task: Task<Void, Error>?
    /// The line asked us to wait in line: the claim is between polls, so calling it off loses nothing.
    private(set) var queued = false

    init(claim: ((_ onWait: @escaping @MainActor () -> Void) async throws -> Void)?) {
        guard let claim else { return }
        task = Task { [weak self] in try await claim { self?.queued = true } }
    }

    /// The lease, claimed (or the claim's error). Cancelling the caller (Stop) calls the claim off too.
    func value() async throws {
        guard let task else { return }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// The start failed: a claim still waiting in line is called off (its place lapses on the server); one on its way
    /// is waited for, so the caller's release (Trial.end) gives that lease back at once instead of leaving it to idle
    /// out (and the device holding it would be refused its next claim until then).
    func settle() async {
        guard let task else { return }
        if queued { task.cancel() }
        _ = try? await task.value
    }
}
