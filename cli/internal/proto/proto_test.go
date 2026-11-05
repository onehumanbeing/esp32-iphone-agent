package proto

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"testing"
	"time"
)

type vframe struct {
	Stream string `json:"stream"`
	Type   byte   `json:"type"`
	Ctr    uint32 `json:"ctr"`
	Plain  string `json:"plain"`
	Frame  string `json:"frame"`
}

type vectors struct {
	CPriv, BPriv, CPub, BPub, Shared, ClientID, BoardID, K, PairMac, CNonce, BNonce, KC2b, KB2c, HelloMac string
	FrameC                                                                                                vframe `json:"frame_c"`
	FrameB                                                                                                vframe `json:"frame_b"`
	FrameV                                                                                                vframe `json:"frame_v"`
}

func (v *vectors) UnmarshalJSON(b []byte) error {
	var m map[string]json.RawMessage
	if err := json.Unmarshal(b, &m); err != nil {
		return err
	}
	str := func(k string) string { var s string; json.Unmarshal(m[k], &s); return s }
	v.CPriv, v.BPriv, v.CPub, v.BPub, v.Shared = str("c_priv"), str("b_priv"), str("c_pub"), str("b_pub"), str("shared")
	v.ClientID, v.BoardID, v.K, v.PairMac = str("client_id"), str("board_id"), str("K"), str("pair_mac")
	v.CNonce, v.BNonce, v.KC2b, v.KB2c, v.HelloMac = str("c_nonce"), str("b_nonce"), str("k_c2b"), str("k_b2c"), str("hello_mac")
	json.Unmarshal(m["frame_c"], &v.FrameC)
	json.Unmarshal(m["frame_b"], &v.FrameB)
	json.Unmarshal(m["frame_v"], &v.FrameV)
	return nil
}

func h(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}

func load(t *testing.T) vectors {
	raw, err := os.ReadFile("../../testdata/vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var v vectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func eq(t *testing.T, name string, got []byte, want string) {
	t.Helper()
	if hex.EncodeToString(got) != want {
		t.Errorf("%s = %x, want %s", name, got, want)
	}
}

func TestVectors(t *testing.T) {
	v := load(t)
	cPriv, _ := ecdh.X25519().NewPrivateKey(h(v.CPriv))
	bPriv, _ := ecdh.X25519().NewPrivateKey(h(v.BPriv))
	eq(t, "c_pub", cPriv.PublicKey().Bytes(), v.CPub)
	eq(t, "b_pub", bPriv.PublicKey().Bytes(), v.BPub)
	shared, _ := cPriv.ECDH(bPriv.PublicKey())
	eq(t, "shared", shared, v.Shared)
	k := PairKey(shared, h(v.CPub), h(v.BPub))
	eq(t, "K", k, v.K)
	eq(t, "pair_mac", PairMAC(k, h(v.ClientID)), v.PairMac)
	eq(t, "hello_mac", HelloMAC(k, h(v.CNonce), h(v.BNonce)), v.HelloMac)
	c2b, b2c := SessionKeys(k, h(v.CNonce), h(v.BNonce))
	eq(t, "k_c2b", c2b, v.KC2b)
	eq(t, "k_b2c", b2c, v.KB2c)
	for _, f := range []vframe{v.FrameC, v.FrameB, v.FrameV} {
		key := b2c
		if f.Stream == "C" {
			key = c2b
		}
		a, _ := NewAEAD(key)
		eq(t, "frame "+f.Stream, a.Seal(f.Stream[0], f.Type, f.Ctr, h(f.Plain)), f.Frame)
		ctr, plain, err := a.Open(f.Stream[0], h(f.Frame))
		if err != nil || ctr != f.Ctr || hex.EncodeToString(plain) != f.Plain {
			t.Errorf("open %s: ctr %d plain %x err %v", f.Stream, ctr, plain, err)
		}
		if _, _, err := a.Open('X', h(f.Frame)); err == nil {
			t.Errorf("frame %s opened with the wrong stream", f.Stream)
		}
	}
}

var (
	clientID = bytes.Repeat([]byte{7}, 16)
	boardID  = h("246f28aa6ad5")
)

func ctx(t *testing.T) context.Context {
	c, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	t.Cleanup(cancel)
	return c
}

// paired returns a session to a fake board that paired with clientID.
func paired(t *testing.T) (*FakeBoard, *Session) {
	b := NewFakeBoard(boardID)
	l := b.Connect()
	k, id, err := Pair(ctx(t), l, clientID)
	if err != nil || !bytes.Equal(id, boardID) {
		t.Fatalf("pair: %v %x", err, id)
	}
	s, err := Hello(ctx(t), l, clientID, func(id []byte) []byte { return k })
	if err != nil {
		t.Fatal(err)
	}
	return b, s
}

func next(t *testing.T, s *Session) (Msg, bool, error) {
	t.Helper()
	select {
	case f := <-s.Recv():
		return s.Decode(f)
	case <-time.After(time.Second):
		t.Fatal("no frame")
	}
	return Msg{}, false, nil
}

func TestPairHelloAndCommand(t *testing.T) {
	b, s := paired(t)
	if err := s.Send("7 ping"); err != nil {
		t.Fatal(err)
	}
	m, ok, err := next(t, s)
	if !ok || err != nil || m.Kind != 'r' || string(m.Data) != "7 ok" {
		t.Fatalf("reply %c %q ok=%v err=%v", m.Kind, m.Data, ok, err)
	}
	b.Status(`{"ap":"streaming"}`)
	m, ok, _ = next(t, s)
	if !ok || m.Kind != 's' || string(m.Data) != `{"ap":"streaming"}` {
		t.Fatalf("status %q", m.Data)
	}
}

func TestBoardSendsNothingBeforeTheClientProvesK(t *testing.T) {
	b, s := paired(t)
	b.Status("{}")
	b.Video(1, 3, []byte{1, 2, 3, 4})
	select {
	case f := <-s.Recv():
		t.Fatalf("got %x before the first DATA frame", f)
	case <-time.After(50 * time.Millisecond):
	}
}

func TestPairingWindowClosedAndUnknownClient(t *testing.T) {
	b := NewFakeBoard(boardID)
	b.PairOpen = false
	_, _, err := Pair(ctx(t), b.Connect(), clientID)
	var be BoardError
	if !errors.As(err, &be) || be != "pairing window closed: unplug and replug the board, then pair within 3 minutes" {
		t.Fatalf("pair outside the window: %v", err)
	}
	_, err = Hello(ctx(t), b.Connect(), clientID, func([]byte) []byte { return nil })
	if !errors.As(err, &be) || be != "not paired" {
		t.Fatalf("hello unknown: %v", err)
	}
}

func TestWrongKeyIsRejected(t *testing.T) {
	b := NewFakeBoard(boardID)
	l := b.Connect()
	if _, _, err := Pair(ctx(t), l, clientID); err != nil {
		t.Fatal(err)
	}
	_, err := Hello(ctx(t), l, clientID, func([]byte) []byte { return make([]byte, 32) })
	if err == nil {
		t.Fatal("hello with a wrong K succeeded")
	}
}

func TestReplayedFramesAreDropped(t *testing.T) {
	b, s := paired(t)
	s.Send("1 ping")
	if _, ok, _ := next(t, s); !ok {
		t.Fatal("first reply dropped")
	}
	sent := b.SentFrames()
	b.Inject(sent[len(sent)-1]) // the same reply again
	if _, ok, err := next(t, s); ok || err != nil {
		t.Fatalf("replayed reply accepted: ok=%v err=%v", ok, err)
	}
	b.Video(1, 3, []byte{0})
	if m, ok, _ := next(t, s); !ok || m.Gap {
		t.Fatal("first video frame")
	}
	sent = b.SentFrames()
	b.Inject(sent[len(sent)-1])
	if _, ok, _ := next(t, s); ok {
		t.Fatal("replayed video accepted")
	}

	// board side: a replayed command is not run twice
	before := len(b.Commands)
	s.Send("2 click")
	next(t, s)
	frame := s.c2b.Seal(StreamC, TData, s.ctrC, []byte("c2 click"))
	s.l.Write(frame)
	if len(b.Commands) != before+1 {
		t.Fatalf("commands %v", b.Commands)
	}
}

func TestControlGapEndsSessionVideoGapDoesNot(t *testing.T) {
	b, s := paired(t)
	s.Send("1 ping")
	next(t, s)
	b.Video(1, 3, []byte{0})
	next(t, s)
	b.mu.Lock()
	b.conn.ctrV++
	b.mu.Unlock()
	b.Video(3, 3, []byte{0})
	if m, ok, err := next(t, s); !ok || err != nil || !m.Gap {
		t.Fatalf("video after a gap: ok=%v err=%v gap=%v", ok, err, m.Gap)
	}
	b.SkipB()
	b.Status("{}")
	if _, _, err := next(t, s); !errors.Is(err, ErrSession) {
		t.Fatalf("control gap: %v", err)
	}
}

func TestClientCounterGapEndsBoardSession(t *testing.T) {
	_, s := paired(t)
	s.Send("1 ping")
	next(t, s)
	s.ctrC++ // one command lost
	s.Send("3 ping")
	select {
	case _, open := <-s.Recv():
		if open {
			t.Fatal("board answered after a counter gap")
		}
	case <-time.After(time.Second):
		t.Fatal("board kept the session")
	}
}
