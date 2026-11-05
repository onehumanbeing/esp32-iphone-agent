// Package proto is the CLI side of docs/cli-protocol.md: pairing, session keys and DATA frames.
package proto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"errors"
)

// Frame types.
const (
	TPair    = 0x01
	TPaired  = 0x81
	THello   = 0x02
	TWelcome = 0x82
	TData    = 0x10
	TVideo   = 0x11
	TError   = 0xE0
)

// Streams, the first nonce byte of a DATA frame.
const (
	StreamC = 'C' // client → board
	StreamB = 'B' // board control
	StreamV = 'V' // board video
)

const (
	tagSize  = 12
	hdrSize  = 5
	keySize  = 32
	idSize   = 16
	nonceLen = 16
	boardLen = 6
	macLen   = 16
)

var errAuth = errors.New("frame does not authenticate")

func derive(ikm, salt, info []byte) []byte {
	k, err := hkdf.Key(sha256.New, ikm, salt, string(info), keySize)
	if err != nil {
		panic(err) // only for impossible lengths
	}
	return k
}

func mac(k []byte, parts ...[]byte) []byte {
	h := hmac.New(sha256.New, k)
	for _, p := range parts {
		h.Write(p)
	}
	return h.Sum(nil)[:macLen]
}

// PairKey is K = HKDF(shared, "esp32agent-pair-v1", c_pub || b_pub).
func PairKey(shared, cPub, bPub []byte) []byte {
	return derive(shared, []byte("esp32agent-pair-v1"), append(append([]byte{}, cPub...), bPub...))
}

// PairMAC is the board's proof in PAIRED.
func PairMAC(k, clientID []byte) []byte { return mac(k, []byte("paired"), clientID) }

// HelloMAC is the board's proof in WELCOME.
func HelloMAC(k, cNonce, bNonce []byte) []byte { return mac(k, []byte("hello"), cNonce, bNonce) }

// SessionKeys returns the AES-128 keys client→board and board→client.
func SessionKeys(k, cNonce, bNonce []byte) (c2b, b2c []byte) {
	okm := derive(k, append(append([]byte{}, cNonce...), bNonce...), []byte("esp32agent-session-v1"))
	return okm[:16], okm[16:]
}

// AEAD is AES-128-GCM with a 12-byte tag.
type AEAD struct{ g cipher.AEAD }

func NewAEAD(key []byte) (*AEAD, error) {
	b, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	g, err := cipher.NewGCMWithTagSize(b, tagSize)
	if err != nil {
		return nil, err
	}
	return &AEAD{g}, nil
}

func nonce(stream byte, ctr uint32) []byte {
	n := make([]byte, 12)
	n[0] = stream
	binary.LittleEndian.PutUint32(n[8:], ctr)
	return n
}

// Seal builds a DATA frame: [type][ctr u32 LE][ciphertext][tag 12].
func (a *AEAD) Seal(stream, typ byte, ctr uint32, plain []byte) []byte {
	hdr := make([]byte, hdrSize, hdrSize+len(plain)+tagSize)
	hdr[0] = typ
	binary.LittleEndian.PutUint32(hdr[1:], ctr)
	return a.g.Seal(hdr, nonce(stream, ctr), plain, hdr[:hdrSize])
}

// Open checks and decrypts a DATA frame; it returns the counter and plaintext.
func (a *AEAD) Open(stream byte, frame []byte) (uint32, []byte, error) {
	if len(frame) < hdrSize+tagSize {
		return 0, nil, errAuth
	}
	ctr := binary.LittleEndian.Uint32(frame[1:hdrSize])
	plain, err := a.g.Open(nil, nonce(stream, ctr), frame[hdrSize:], frame[:hdrSize])
	if err != nil {
		return 0, nil, errAuth
	}
	return ctr, plain, nil
}
