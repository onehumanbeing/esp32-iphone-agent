package daemon

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/ble"
	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/config"
	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/proto"
)

type fakeTransport struct{ b *proto.FakeBoard }

func (f fakeTransport) Scan(context.Context, time.Duration) ([]ble.Found, error) {
	return []ble.Found{{Name: "ESP32 Agent 6AD5", Addr: "fake"}}, nil
}

func (f fakeTransport) Connect(context.Context, ble.Found) (proto.Link, error) {
	return f.b.Connect(), nil
}

// start runs a daemon in process on a short temp dir (unix socket paths are limited to ~100 bytes).
func start(t *testing.T, tr ble.Transport) (*Client, *Server) {
	dir, err := os.MkdirTemp("/tmp", "e32a")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	t.Setenv("ESP32AGENT_HOME", dir)
	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	l, err := Listen(dir)
	if err != nil {
		t.Fatal(err)
	}
	s := &Server{Transport: tr, Config: cfg, Dir: dir, Version: "test", ScanTime: time.Millisecond}
	go s.Serve(l)
	t.Cleanup(s.Stop)
	return &Client{Dir: dir, Version: "test", NoSpawn: true}, s
}

func call(t *testing.T, c *Client, req Request) (Response, map[string]any) {
	t.Helper()
	line, err := c.Call(req)
	if err != nil {
		t.Fatal(err)
	}
	var r Response
	if err := json.Unmarshal(line, &r); err != nil {
		t.Fatalf("%s: %v", line, err)
	}
	data, _ := r.Data.(map[string]any)
	return r, data
}

func fakeBoard() *proto.FakeBoard {
	b, _ := hex.DecodeString("246f28aa6ad5")
	return proto.NewFakeBoard(b)
}

func TestPairInfoAndBusy(t *testing.T) {
	b := fakeBoard()
	busy := false
	b.Handle = func(cmd string) string {
		if busy && cmd != "stream on" {
			return "err busy: the app is using the board"
		}
		return "ok"
	}
	c, s := start(t, fakeTransport{b})

	if r, _ := call(t, c, Request{Cmd: "info"}); r.Status != "error" || !strings.Contains(r.Error, "not paired") {
		t.Fatalf("info before pairing: %+v", r)
	}
	r, data := call(t, c, Request{Cmd: "pair"})
	if r.Status != "ok" || data["id"] != "246f28aa6ad5" {
		t.Fatalf("pair: %+v", r)
	}
	if s.Config.Key(mustHex("246f28aa6ad5")) == nil {
		t.Fatal("key not stored")
	}
	st, err := os.Stat(s.Dir + "/config.json")
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("config.json mode %v %v", st.Mode(), err)
	}

	b.Status(`{"fw":"0.2.1","up":5000,"ap":"idle","fz":0,"busy":0,"ble":{"mtu":247,"n":2}}`)
	b.Status(`{"up":6000,"ap":"idle","ble":{"mtu":23}}`) // the compact form keeps the rest
	time.Sleep(50 * time.Millisecond)
	r, data = call(t, c, Request{Cmd: "info"})
	ble, _ := data["ble"].(map[string]any)
	if r.Status != "ok" || data["fw"] != "0.2.1" || data["up"] != 6000.0 || ble["mtu"] != 23.0 || ble["n"] != 2.0 || data["busy"] != 0.0 {
		t.Fatalf("info: %+v", data)
	}

	if r, _ := call(t, c, Request{Cmd: "keys", Text: "Enter"}); r.Status != "ok" {
		t.Fatalf("keys: %+v", r)
	}
	if r, _ := call(t, c, Request{Cmd: "screenshot"}); r.Status != "error" || !strings.Contains(r.Error, "mirroring is off") {
		t.Fatalf("screenshot without mirroring: %+v", r)
	}
	busy = true
	if r, _ := call(t, c, Request{Cmd: "text", Text: "hi"}); r.Status != "error" || r.Error != ErrAppBusy.Error() {
		t.Fatalf("busy: %+v", r)
	}
	b.Status(`{"ap":"streaming","fz":1}`)
	time.Sleep(50 * time.Millisecond)
	if r, _ := call(t, c, Request{Cmd: "screenshot"}); r.Status != "error" || !strings.Contains(r.Error, "restart Screen Mirroring") {
		t.Fatalf("frozen: %+v", r)
	}
	if got := strings.Join(b.Commands, ","); got != "stream on,key enter,type hi" {
		t.Fatalf("board got %s", got)
	}
	if r, _ := call(t, c, Request{Cmd: "button", Text: "VOLUME_UP"}); r.Status != "error" {
		t.Fatal("volume button accepted")
	}

	r, _ = call(t, c, Request{Cmd: "unpair"})
	if r.Status != "ok" || s.Config.Key(mustHex("246f28aa6ad5")) != nil {
		t.Fatalf("unpair: %+v", r)
	}
}

func TestPairingWindowClosed(t *testing.T) {
	b := fakeBoard()
	b.PairOpen = false
	c, _ := start(t, fakeTransport{b})
	if r, _ := call(t, c, Request{Cmd: "pair"}); r.Status != "error" || !strings.Contains(r.Error, "pairing window closed") {
		t.Fatalf("pair: %+v", r)
	}
}

func TestReconnectsAfterTheLinkDrops(t *testing.T) {
	b := fakeBoard()
	c, _ := start(t, fakeTransport{b})
	call(t, c, Request{Cmd: "pair"})
	b.Inject([]byte{proto.TData, 9, 9, 9, 9}) // garbage is dropped, the session stays
	b.SkipB()
	b.Status(`{}`) // a control counter gap ends the session
	time.Sleep(50 * time.Millisecond)
	if r, _ := call(t, c, Request{Cmd: "keys", Text: "esc"}); r.Status != "ok" {
		t.Fatalf("after reconnect: %+v", r)
	}
	if got := strings.Join(b.Commands, ","); got != "stream on,stream on,key esc" {
		t.Fatalf("board got %s", got)
	}
}

func mustHex(s string) []byte { b, _ := hex.DecodeString(s); return b }
