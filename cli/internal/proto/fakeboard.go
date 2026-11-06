package proto

import (
	"crypto/ecdh"
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"io"
	"strings"
	"sync"
)

// FakeBoard is the board side of docs/cli-protocol.md, in process, for tests.
type FakeBoard struct {
	ID       []byte
	PairOpen bool
	// Handle answers one command (without the id), e.g. "ok" or "err unknown command".
	Handle func(cmd string) string

	mu       sync.Mutex
	keys     map[string][]byte // client_id hex → K
	conn     *fakeConn
	Commands []string // every command accepted on stream C, in order
}

func NewFakeBoard(id []byte) *FakeBoard {
	return &FakeBoard{ID: id, PairOpen: true, keys: map[string][]byte{}, Handle: func(string) string { return "ok" }}
}

type fakeConn struct {
	b         *FakeBoard
	toClient  chan []byte
	closeOnce sync.Once
	closed    chan struct{}

	c2b, b2c         *AEAD
	authed           bool
	ctrC             uint32
	ctrB, ctrV, ctrA uint32
	Sent             [][]byte
}

// Connect returns the client end of a new connection; the board serves it until Close.
func (b *FakeBoard) Connect() Link {
	c := &fakeConn{b: b, toClient: make(chan []byte, 1024), closed: make(chan struct{})}
	b.mu.Lock()
	b.conn = c
	b.mu.Unlock()
	return c
}

func (c *fakeConn) Recv() <-chan []byte { return c.toClient }

func (c *fakeConn) Close() error {
	c.closeOnce.Do(func() {
		close(c.closed)
		c.b.mu.Lock()
		close(c.toClient)
		c.b.mu.Unlock()
	})
	return nil
}

// send must hold b.mu.
func (c *fakeConn) send(f []byte) {
	select {
	case <-c.closed:
	default:
		c.Sent = append(c.Sent, f)
		c.toClient <- f
	}
}

func (c *fakeConn) Write(f []byte) error {
	select {
	case <-c.closed:
		return io.ErrClosedPipe
	default:
	}
	if len(f) == 0 {
		return nil
	}
	b := c.b
	b.mu.Lock()
	defer b.mu.Unlock()
	switch f[0] {
	case TPair:
		if !b.PairOpen {
			c.send(append([]byte{TError}, "pairing window closed: unplug and replug the board, then pair within 3 minutes"...))
			return nil
		}
		if len(f) != 1+keySize+idSize {
			return nil
		}
		priv, _ := ecdh.X25519().GenerateKey(rand.Reader)
		cPub, err := ecdh.X25519().NewPublicKey(f[1 : 1+keySize])
		if err != nil {
			return nil
		}
		shared, _ := priv.ECDH(cPub)
		bPub := priv.PublicKey().Bytes()
		clientID := f[1+keySize:]
		k := PairKey(shared, f[1:1+keySize], bPub)
		b.keys[hex.EncodeToString(clientID)] = k
		c.send(append(append(append([]byte{TPaired}, bPub...), b.ID...), PairMAC(k, clientID)...))
	case THello:
		if len(f) != 1+idSize+nonceLen {
			return nil
		}
		k := b.keys[hex.EncodeToString(f[1:1+idSize])]
		if k == nil {
			c.send(append([]byte{TError}, "not paired"...))
			return nil
		}
		cNonce := f[1+idSize:]
		bNonce := make([]byte, nonceLen)
		io.ReadFull(rand.Reader, bNonce)
		c2b, b2c := SessionKeys(k, cNonce, bNonce)
		c.c2b, _ = NewAEAD(c2b)
		c.b2c, _ = NewAEAD(b2c)
		c.authed, c.ctrC, c.ctrB, c.ctrV, c.ctrA = false, 0, 0, 0, 0
		c.send(append(append(append([]byte{TWelcome}, bNonce...), b.ID...), HelloMAC(k, cNonce, bNonce)...))
	case TData:
		if c.c2b == nil {
			return nil
		}
		ctr, plain, err := c.c2b.Open(StreamC, f)
		if err != nil || ctr <= c.ctrC || len(plain) < 2 || plain[0] != 'c' {
			return nil // forged or replayed: dropped
		}
		if ctr != c.ctrC+1 {
			go c.Close() // a gap on C ends the session
			return nil
		}
		c.ctrC, c.authed = ctr, true
		id, cmd, _ := strings.Cut(string(plain[1:]), " ")
		b.Commands = append(b.Commands, cmd)
		if reply := b.Handle(cmd); reply != "" {
			c.sealB('r', id+" "+reply)
		}
	}
	return nil
}

func (c *fakeConn) sealB(kind byte, s string) {
	c.ctrB++
	c.send(c.b2c.Seal(StreamB, TData, c.ctrB, append([]byte{kind}, s...)))
}

// Status sends a status JSON to an authenticated client.
func (b *FakeBoard) Status(json string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if c := b.conn; c != nil && c.authed {
		c.sealB('s', json)
	}
}

// Reply sends a reply line (e.g. a late snap answer) to an authenticated client.
func (b *FakeBoard) Reply(line string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if c := b.conn; c != nil && c.authed {
		c.sealB('r', line)
	}
}

// Video sends one video chunk [seq][flags][payload] on stream V.
func (b *FakeBoard) Video(seq uint16, flags byte, payload []byte) {
	b.mu.Lock()
	defer b.mu.Unlock()
	c := b.conn
	if c == nil || !c.authed {
		return
	}
	chunk := make([]byte, 3, 3+len(payload))
	binary.LittleEndian.PutUint16(chunk, seq)
	chunk[2] = flags
	c.ctrV++
	c.send(c.b2c.Seal(StreamV, TVideo, c.ctrV, append(chunk, payload...)))
}

// Audio sends one phone audio record (stream A) to the authenticated client.
func (b *FakeBoard) Audio(rec []byte) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if c := b.conn; c != nil && c.authed {
		c.ctrA++
		c.send(c.b2c.Seal(StreamA, TAudio, c.ctrA, rec))
	}
}

// Inject delivers a raw frame to the client (replays, forgeries).
func (b *FakeBoard) Inject(f []byte) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.conn != nil {
		b.conn.send(f)
	}
}

// SentFrames returns the frames sent on the current connection.
func (b *FakeBoard) SentFrames() [][]byte {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.conn == nil {
		return nil
	}
	return append([][]byte{}, b.conn.Sent...)
}

// SkipB makes the next control frame jump its counter (a lost frame).
func (b *FakeBoard) SkipB() {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.conn != nil {
		b.conn.ctrB++
	}
}
