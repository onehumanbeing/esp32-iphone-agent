import Foundation

/// One AirPlay audio record from the board's TCP video link (docs/ble-protocol.md, "Wi-Fi audio"):
/// [seq u16 LE][flags][payload] with flag 0x80 set, its own seq. Payload: [u32 LE board ms][u32 LE RTP ts]
/// [AAC-ELD frame]. A segment of sound starts with a .start record and ends with an empty .end record.
struct AudioRecord: Equatable {
    static let flag: UInt8 = 0x80
    static let startFlag: UInt8 = 1, endFlag: UInt8 = 2  // VF_START / VF_END

    let seq: UInt16
    let start: Bool, end: Bool
    let boardMs: UInt32
    let rtpTs: UInt32
    let frame: Data

    /// Audio, not a video chunk (which never sets 0x80).
    static func isAudio(_ chunk: Data) -> Bool {
        chunk.count >= 3 && chunk[chunk.startIndex + 2] & flag != 0
    }

    init?(_ chunk: Data) {
        let b = [UInt8](chunk)
        guard b.count >= 3, b[2] & Self.flag != 0 else { return nil }
        seq = UInt16(b[0]) | UInt16(b[1]) << 8
        start = b[2] & Self.startFlag != 0
        end = b[2] & Self.endFlag != 0
        if end {
            (boardMs, rtpTs, frame) = (0, 0, Data())
            return
        }
        guard b.count > 11 else { return nil }
        func le32(_ i: Int) -> UInt32 { UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24 }
        boardMs = le32(3)
        rtpTs = le32(7)
        frame = Data(b[11...])
    }
}
