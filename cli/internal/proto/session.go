package proto

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/hmac"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"sync"
)

// Link is one connection to the board's cli service: frames written to cli_in, notifies from cli_out.
type Link interface {
	Write(frame []byte) error
	Recv() <-chan []byte // closed when the link drops
	Close() error
}

// BoardError is a plain 0xE0 frame from the board.
type BoardError string

func (e BoardError) Error() string { return string(e) }

// ErrSession ends a session: a counter gap on the control stream, or the link dropped.
var ErrSession = errors.New("session lost (reconnect)")

func recv(ctx context.Context, l Link, want byte) ([]byte, error) {
	for {
		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("no answer from the board: %w", ctx.Err())
		case f, ok := <-l.Recv():
			if !ok {
				return nil, ErrSession
			}
			if len(f) == 0 {
				continue
			}
			switch f[0] {
			case want:
				return f[1:], nil
			case TError:
				return nil, BoardError(f[1:])
			}
		}
	}
}

// Pair runs PAIR → PAIRED and returns K and the board id.
func Pair(ctx context.Context, l Link, clientID []byte) (k []byte, boardID []byte, err error) {
	priv, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	cPub := priv.PublicKey().Bytes()
	if err := l.Write(append(append([]byte{TPair}, cPub...), clientID...)); err != nil {
		return nil, nil, err
	}
	body, err := recv(ctx, l, TPaired)
	if err != nil {
		return nil, nil, err
	}
	if len(body) != keySize+boardLen+macLen {
		return nil, nil, errors.New("bad PAIRED frame")
	}
	bPub, err := ecdh.X25519().NewPublicKey(body[:keySize])
	if err != nil {
		return nil, nil, err
	}
	shared, err := priv.ECDH(bPub)
	if err != nil {
		return nil, nil, err
	}
	k = PairKey(shared, cPub, body[:keySize])
	if !hmac.Equal(PairMAC(k, clientID), body[keySize+boardLen:]) {
		return nil, nil, errors.New("pairing proof does not match")
	}
	return k, bytes.Clone(body[keySize : keySize+boardLen]), nil
}

// Session is an authenticated connection after HELLO/WELCOME.
type Session struct {
	l        Link
	BoardID  []byte
	c2b, b2c *AEAD
	mu       sync.Mutex
	ctrC     uint32
	ctrB     uint32
	ctrV     uint32
}

// Hello opens a session. keyFor returns K for a board id (nil: not paired with it).
func Hello(ctx context.Context, l Link, clientID []byte, keyFor func(boardID []byte) []byte) (*Session, error) {
	cNonce := make([]byte, nonceLen)
	if _, err := io.ReadFull(rand.Reader, cNonce); err != nil {
		return nil, err
	}
	if err := l.Write(append(append([]byte{THello}, clientID...), cNonce...)); err != nil {
		return nil, err
	}
	body, err := recv(ctx, l, TWelcome)
	if err != nil {
		return nil, err
	}
	if len(body) != nonceLen+boardLen+macLen {
		return nil, errors.New("bad WELCOME frame")
	}
	bNonce, boardID := body[:nonceLen], bytes.Clone(body[nonceLen:nonceLen+boardLen])
	k := keyFor(boardID)
	if k == nil {
		return nil, fmt.Errorf("not paired with board %s: run esp32agent pair", hex.EncodeToString(boardID))
	}
	if !hmac.Equal(HelloMAC(k, cNonce, bNonce), body[nonceLen+boardLen:]) {
		return nil, errors.New("board proof does not match (paired with another key? run esp32agent pair)")
	}
	c2b, b2c := SessionKeys(k, cNonce, bNonce)
	s := &Session{l: l, BoardID: boardID}
	if s.c2b, err = NewAEAD(c2b); err != nil {
		return nil, err
	}
	if s.b2c, err = NewAEAD(b2c); err != nil {
		return nil, err
	}
	return s, nil
}

// Send writes one command line `<id> <command>` on stream C.
func (s *Session) Send(line string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ctrC++
	return s.l.Write(s.c2b.Seal(StreamC, TData, s.ctrC, append([]byte{'c'}, line...)))
}

// Msg is one decrypted board message.
type Msg struct {
	Kind byte   // 'r' reply line, 's' status JSON, 'v' video chunk
	Data []byte // without the kind byte (a video chunk as is)
	Gap  bool   // video: frames were lost before this one
}

// Decode authenticates a frame from the board. ok=false: drop it (forged, replayed). An error ends the session.
func (s *Session) Decode(f []byte) (m Msg, ok bool, err error) {
	if len(f) == 0 {
		return m, false, nil
	}
	switch f[0] {
	case TData:
		ctr, plain, err := s.b2c.Open(StreamB, f)
		if err != nil || ctr <= s.ctrB || len(plain) == 0 {
			return m, false, nil
		}
		if ctr != s.ctrB+1 {
			return m, false, ErrSession
		}
		s.ctrB = ctr
		return Msg{Kind: plain[0], Data: plain[1:]}, true, nil
	case TVideo:
		ctr, plain, err := s.b2c.Open(StreamV, f)
		if err != nil || ctr <= s.ctrV {
			return m, false, nil
		}
		gap := ctr != s.ctrV+1
		s.ctrV = ctr
		return Msg{Kind: 'v', Data: plain, Gap: gap}, true, nil
	case TError:
		return m, false, BoardError(f[1:])
	}
	return m, false, nil
}

func (s *Session) Recv() <-chan []byte { return s.l.Recv() }
func (s *Session) Close() error        { return s.l.Close() }
