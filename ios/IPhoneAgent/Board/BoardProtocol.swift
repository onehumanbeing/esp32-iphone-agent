import CoreBluetooth
import Foundation

/// GATT layout and message formats from docs/ble-protocol.md.
enum BoardUUID {
    static func make(_ suffix: String) -> CBUUID { CBUUID(string: "6e400001-a9e8-4b1b-9c39-6d6f8a3c" + suffix) }
    static let service = make("0000")
    static let cmd = make("0001")
    static let reply = make("0002")
    static let status = make("0003")
    static let video = make("0004")
    static let net = make("0005")
    static let all = [cmd, reply, status, video, net]
}

/// The 1 s JSON heartbeat on `status`.
struct BoardStatus: Codable, Equatable {
    struct BLE: Codable, Equatable {
        var mtu: Int?, phy: Int?, kbps: Double?, drop: Int?
    }
    /// The Wi-Fi video session (VideoSocket): n = 1 while the board sends video over UDP.
    struct UDP: Codable, Equatable {
        var n: Int?, kbps: Double?, nack: Int?, drop: Int?
    }
    var fw: FirmwareVersion?  // firmware version (hardware/hid_bridge/version.h); boards before OTA don't send it
    var up: Int?
    var rst: String?
    var heap: Int?
    var psram: Int?
    var usb: String?   // ok | asleep | off
    var net: String?   // ap | sta | none
    var ip: String?
    var sta: Int?
    var ap: String?    // idle | connected | streaming
    var w: Int?, h: Int?
    var kbps: Double?, fps: Double?, idr: Int?, gop: Int?
    var vage: Int?     // ms since the board's last frame from AirPlay (firmware 0.2.1+)
    var ovf: Int?      // times the board's GOP buffer filled up (0.2.2+)
    var fz: Int?       // 1: GOP full, no new frame until mirroring sends a keyframe (0.2.2+; nil = 0)
    var ble: BLE?
    var udp: UDP?

    static func decode(_ data: Data) -> BoardStatus? { try? JSONDecoder().decode(BoardStatus.self, from: data) }

    /// A small MTU makes the board notify a reduced object (up, usb, net, ap, ble.mtu); a `status` read returns
    /// the full one. Newer fields win, missing ones keep their last value.
    func merged(with n: BoardStatus) -> BoardStatus {
        var m = n
        m.fw = n.fw ?? fw
        m.up = n.up ?? up; m.rst = n.rst ?? rst; m.heap = n.heap ?? heap; m.psram = n.psram ?? psram
        m.usb = n.usb ?? usb; m.net = n.net ?? net; m.ip = n.ip ?? ip; m.sta = n.sta ?? sta; m.ap = n.ap ?? ap
        m.w = n.w ?? w; m.h = n.h ?? h; m.kbps = n.kbps ?? kbps; m.fps = n.fps ?? fps; m.idr = n.idr ?? idr
        m.gop = n.gop ?? gop; m.vage = n.vage ?? vage; m.ovf = n.ovf ?? ovf; m.fz = n.fz ?? fz
        let a = ble ?? BLE(), b = n.ble ?? BLE()
        m.ble = BLE(mtu: b.mtu ?? a.mtu, phy: b.phy ?? a.phy, kbps: b.kbps ?? a.kbps, drop: b.drop ?? a.drop)
        m.udp = n.udp ?? udp
        return m
    }
}

/// The `net` characteristic: SoftAP credentials (read) or Wi-Fi mode (write).
struct NetConfig: Codable, Equatable {
    var mode: String
    var ssid: String?
    var pass: String?
    var ip: String?
    var vtok: String?  // per-boot token for the Wi-Fi video channel (VideoSocket)
}

/// A `reply` notify: `<id> ok [extra]` or `<id> err <reason>`.
struct BoardReply: Equatable {
    let id: Int
    let ok: Bool
    let text: String  // extra after "ok", or the error reason

    static func parse(_ line: String) -> BoardReply? {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2)
            .map(String.init)
        guard parts.count >= 2, let id = Int(parts[0]), parts[1] == "ok" || parts[1] == "err" else { return nil }
        return BoardReply(id: id, ok: parts[1] == "ok", text: parts.count > 2 ? parts[2] : "")
    }
}
