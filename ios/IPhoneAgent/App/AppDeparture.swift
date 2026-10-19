import Foundation

/// A command acknowledgement is not proof that iOS left the app. Verify each independent method.
@MainActor struct AppDeparture {
    /// The home-bar flick first: on iPhone the board's Home key and Cmd+H are acknowledged but iOS ignores
    /// them (2026-10-17 log), and each miss cost ~2 s before the flick.
    enum Method: String, CaseIterable {
        case swipe = "Home swipe", homeKey = "Home key", shortcut = "Cmd+H"
    }

    let isBackground: () -> Bool
    let isConnected: () -> Bool
    let attempt: (Method) async throws -> Void
    let waitForBackground: (Double) async throws -> Bool
    var waitForConnection: () async throws -> Void = {
        throw DeviceError(message: String(localized: "The board disconnected. Move it closer to your iPhone, reconnect, then try again."))
    }
    var failed: (Method, Error) -> Void = { _, _ in }
    var log: (String) -> Void = { _ in }

    func leave() async throws -> Bool {
        for method in Method.allCases {
            while true {
                try Task.checkCancellation()
                if isBackground() { return true }
                if !isConnected() { try await waitForConnection() }
                try Task.checkCancellation()
                if isBackground() { return true }  // the user may have left while the board reconnected
                do {
                    try await attempt(method)
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError { throw error }
                    failed(method, error)
                    if !isConnected() { continue }  // reconnect, then retry this same method
                    break
                }
                try Task.checkCancellation()
                if try await waitForBackground(2) {
                    log("leave app: in background after \(method.rawValue)")
                    return true
                }
                if !isConnected() { continue }
                log("leave app: still in front after \(method.rawValue)")
                break
            }
        }
        return false
    }
}
