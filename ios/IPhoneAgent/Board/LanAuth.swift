import CommonCrypto
import CryptoKit
import Foundation

/// The LAN lock's app side (hardware/hid_bridge/src/net/lan_lock.h, docs/ble-protocol.md "LAN mode"). On a home
/// network the per-boot token never goes over the air: the board sends a nonce and the app answers with
/// HMAC-SHA256(token, message with the nonce). The video session it opens is AES-128-CTR encrypted.
enum LanAuth {
    /// Firmware with the lock reports `own` in its status (0 or 1); older boards don't, and get the plain token.
    static func supported(_ status: BoardStatus?) -> Bool { status?.own != nil }

    /// HMAC-SHA256(token, message), lower-case hex.
    static func mac(token: String, _ message: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(token.utf8)))
        return code.map { String(format: "%02x", $0) }.joined()
    }

    /// The `auth` line's proof for a video session.
    static func video(token: String, nonce: String) -> String { mac(token: token, "video \(nonce)") }

    /// The `ota2` header's proof: binds the image's size and SHA-256 to this connection's nonce.
    static func ota(token: String, nonce: String, size: Int, sha256: String) -> String {
        mac(token: token, "ota \(nonce) \(size) \(sha256.lowercased())")
    }

    /// The nonce in a `chal` record (the board's answer to "chal" on the video channel): "chal" + 32 hex characters.
    static func challenge(_ record: Data) -> String? {
        guard record.count == 36, record.prefix(4) == Data("chal".utf8) else { return nil }
        let nonce = String(decoding: record.dropFirst(4), as: UTF8.self)
        return nonce.allSatisfy(\.isHexDigit) ? nonce : nil
    }

    /// One encrypted session: a single AES-128-CTR keystream over every non-empty record, in order, from a zero
    /// counter. Key: the first 16 bytes of HMAC-SHA256(token, "video key " + nonce).
    final class Stream {
        private var cryptor: CCCryptorRef?

        init?(token: String, nonce: String) {
            let code = HMAC<SHA256>.authenticationCode(for: Data("video key \(nonce)".utf8),
                                                       using: SymmetricKey(data: Data(token.utf8)))
            let key = Array(Data(code).prefix(16)), iv = [UInt8](repeating: 0, count: 16)
            let status = CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                                 CCPadding(ccNoPadding), iv, key, key.count, nil, 0, 0,
                                                 CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
            guard status == kCCSuccess, cryptor != nil else { return nil }
        }

        deinit { if let cryptor { CCCryptorRelease(cryptor) } }

        /// Encrypts or decrypts (the same in CTR), going on where the last call stopped.
        func crypt(_ data: Data) -> Data {
            guard let cryptor, !data.isEmpty else { return data }
            var out = Data(count: data.count)
            var moved = 0
            let status = out.withUnsafeMutableBytes { o in
                data.withUnsafeBytes { i in
                    CCCryptorUpdate(cryptor, i.baseAddress, data.count, o.baseAddress, data.count, &moved)
                }
            }
            return status == kCCSuccess && moved == data.count ? out : Data()
        }
    }
}
