import Foundation

/// A phone-only Shortcuts transaction. Shortcuts receives one leased JSON packet, copies its text locally,
/// reads its own clipboard back, and acknowledges the same ID and bytes. No HTTP server or Mac is involved.
struct LocalCopySession {
    struct Packet: Codable {
        let id: UUID
        let text: String
    }
    struct Pending {
        let packet: Packet
        let expires: Double
        let requiresBoard: Bool
        var claimed = false
        var completed = false
    }
    private(set) var pending: Pending?
    static let timeout = 20.0

    mutating func begin(_ text: String, at: Double, timeout: Double = Self.timeout, requiresBoard: Bool = true) throws -> UUID {
        guard pending == nil, !text.isEmpty, text.utf8.count <= 65_536 else { throw failure("A local copy is already pending, or the text is empty/too long.") }
        guard timeout.isFinite, timeout > 0 else { throw failure("Invalid local copy timeout.") }
        let packet = Packet(id: UUID(), text: text)
        pending = Pending(packet: packet, expires: at + timeout, requiresBoard: requiresBoard)
        return packet.id
    }

    mutating func claim(at: Double) throws -> String {
        guard var p = pending, at < p.expires, !p.claimed else { throw failure("There is no new local input request. Start input from ESP32 Agent first.") }
        p.claimed = true
        pending = p
        return String(decoding: try JSONEncoder().encode(p.packet), as: UTF8.self)
    }

    mutating func acknowledge(id: String, text: String, at: Double) throws {
        guard var p = pending, UUID(uuidString: id) == p.packet.id, p.claimed, !p.completed,
              at < p.expires, text.utf8.elementsEqual(p.packet.text.utf8) else {
            throw failure("The shortcut did not return this request's exact copied text before it expired.")
        }
        p.completed = true
        pending = p
    }

    func completed(_ id: UUID, at: Double) -> Bool {
        guard let p = pending else { return false }
        return p.packet.id == id && p.completed && at < p.expires
    }

    var progress: String {
        guard let p = pending else { return "Ready" }
        if p.completed { return "Exact copied text acknowledged" }
        return p.claimed ? "Shortcut received text; waiting for copy confirmation" : "Waiting for shortcut to request text"
    }

    var timeoutMessage: String {
        if pending?.claimed == true {
            return "The shortcut received the text but did not confirm the copy. Open Shortcuts and check the failing action or permission request. Nothing pasted."
        }
        return "The shortcut never requested text from this app. Check that Handsy Local Copy is imported and its trigger runs on this iPhone. Nothing pasted."
    }

    mutating func cancel(_ id: UUID? = nil) {
        if id == nil || pending?.packet.id == id { pending = nil }
    }

    private func failure(_ text: String) -> DeviceError { DeviceError(message: text) }
}

/// BLE and the board's USB status do not identify the USB host. A board plugged into a Mac can report
/// both as connected while every gesture goes to that Mac. Require an input accessory on this phone too.
enum LocalCopyPreflight {
    static func issue(boardConnected: Bool, usb: String?, keyboard: Bool, mouse: Bool, button: Bool) -> String? {
        guard boardConnected, usb == "ok" else { return "Connect the ESP32 USB cable to this iPhone and keep Bluetooth connected. No trigger sent." }
        guard keyboard, !button || mouse else {
            return "This iPhone has not detected the required USB keyboard/mouse. Connect ESP32 directly to this iPhone, not the Mac; Bluetooth alone cannot send input to this phone. No trigger sent."
        }
        return nil
    }
}

enum LocalCopyConfig {
    static let verifiedKey = "localCopyShortcutVerifiedV1"
    static let shortcutCheckedKey = "localCopyShortcutCheckedV1"
    static let triggerKey = "localCopyShortcutTrigger"
    static let comboKey = "localCopyShortcutKeys"
    static let xKey = "localCopyButtonX", yKey = "localCopyButtonY"
    static let name = "Handsy Local Copy"
    static var verified: Bool { UserDefaults.standard.bool(forKey: verifiedKey) }
    static var combo: String { UserDefaults.standard.string(forKey: comboKey) ?? "ctrl+alt+shift+v" }
    static var useButton: Bool { UserDefaults.standard.string(forKey: triggerKey) == "button" }
    static var point: CGPoint {
        let d = UserDefaults.standard
        return CGPoint(x: d.object(forKey: xKey) as? Double ?? 0.1,
                       y: d.object(forKey: yKey) as? Double ?? 0.86)
    }
}
