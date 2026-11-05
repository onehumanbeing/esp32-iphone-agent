# /// script
# dependencies = ["cryptography>=42"]
# ///
"""Writes vectors.json for docs/cli-protocol.md from fixed inputs (uv run gen_vectors.py)."""
import hashlib, hmac, json
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

def pub(k): return k.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
def hkdf(ikm, salt, info, n=32): return HKDF(hashes.SHA256(), n, salt, info).derive(ikm)
def mac(k, m): return hmac.new(k, m, hashlib.sha256).digest()[:16]

c_priv = bytes(range(1, 33)); b_priv = bytes(range(101, 133))
ck, bk = X25519PrivateKey.from_private_bytes(c_priv), X25519PrivateKey.from_private_bytes(b_priv)
c_pub, b_pub = pub(ck), pub(bk)
shared = bk.exchange(ck.public_key())
client_id = bytes(range(0xA0, 0xB0)); board_id = bytes.fromhex("246f28aa6ad5")
K = hkdf(shared, b"esp32agent-pair-v1", c_pub + b_pub)
c_nonce, b_nonce = bytes(range(0x10, 0x20)), bytes(range(0x20, 0x30))
okm = hkdf(K, c_nonce + b_nonce, b"esp32agent-session-v1")
k_c2b, k_b2c = okm[:16], okm[16:]

def seal(key, stream, typ, ctr, plain):
    hdr = bytes([typ]) + ctr.to_bytes(4, "little")
    nonce = stream.encode() + bytes(7) + ctr.to_bytes(4, "little")
    ct = AESGCM(key).encrypt(nonce, plain, hdr)  # ciphertext || 16-byte tag
    return (hdr + ct[:-16] + ct[-16:-4]).hex()  # tag truncated to 12 bytes

# A 12-byte GCM tag is the first 12 bytes of the full one (NIST SP 800-38D truncation).
v = {
    "c_priv": c_priv.hex(), "b_priv": b_priv.hex(), "c_pub": c_pub.hex(), "b_pub": b_pub.hex(),
    "shared": shared.hex(), "client_id": client_id.hex(), "board_id": board_id.hex(), "K": K.hex(),
    "pair_mac": mac(K, b"paired" + client_id).hex(),
    "c_nonce": c_nonce.hex(), "b_nonce": b_nonce.hex(), "k_c2b": k_c2b.hex(), "k_b2c": k_b2c.hex(),
    "hello_mac": mac(K, b"hello" + c_nonce + b_nonce).hex(),
    "frame_c": {"stream": "C", "type": 16, "ctr": 1, "plain": (b"c" + b"7 ping").hex(), "frame": seal(k_c2b, "C", 0x10, 1, b"c7 ping")},
    "frame_b": {"stream": "B", "type": 16, "ctr": 2, "plain": (b"r7 ok").hex(), "frame": seal(k_b2c, "B", 0x10, 2, b"r7 ok")},
    "frame_v": {"stream": "V", "type": 17, "ctr": 1, "plain": "0100050000000001", "frame": seal(k_b2c, "V", 0x11, 1, bytes.fromhex("0100050000000001"))},
}
json.dump(v, open("vectors.json", "w"), indent=1)
print(json.dumps(v)[:200])
