package daemon

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/proto"
)

func waitVia(t *testing.T, s *Server, want string) {
	t.Helper()
	for i := 0; i < 100; i++ {
		s.mu.Lock()
		c := s.conns["246f28aa6ad5"]
		s.mu.Unlock()
		if c != nil && c.Via() == want {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("session never went to %s", want)
}

func TestSessionMovesToWiFiAndBack(t *testing.T) {
	b := fakeBoard()
	var mu sync.Mutex
	var wifi proto.Link
	var dialed string
	c, s := startWith(t, fakeTransport{b}, func(_ context.Context, ip string) (proto.Link, error) {
		mu.Lock()
		defer mu.Unlock()
		dialed, wifi = ip, b.Connect()
		return wifi, nil
	})
	s.WiFiCheck = 20 * time.Millisecond
	if r, _ := call(t, c, Request{Cmd: "pair"}); r.Status != "ok" {
		t.Fatalf("pair: %+v", r)
	}
	b.Status(`{"net":"ap","ip":"192.168.4.1"}`)
	waitVia(t, s, "wifi")
	if r, _ := call(t, c, Request{Cmd: "keys", Text: "esc"}); r.Status != "ok" {
		t.Fatalf("keys over Wi-Fi: %+v", r)
	}
	mu.Lock()
	if dialed != "192.168.4.1" {
		t.Fatalf("dialed %q", dialed)
	}
	wifi.Close() // the Wi-Fi link drops: back to the BLE link, still up
	mu.Unlock()
	waitVia(t, s, "ble")
	if r, _ := call(t, c, Request{Cmd: "keys", Text: "esc"}); r.Status != "ok" {
		t.Fatalf("keys after falling back: %+v", r)
	}
	if got := strings.Join(b.Commands, ","); got != "stream on,stream on,key esc,stream on,key esc" {
		t.Fatalf("board got %s", got)
	}
	if r, data := call(t, c, Request{Cmd: "net", Text: "via ble"}); r.Status != "error" || data != nil {
		t.Fatalf("net on a board without it: %+v", r) // the fake board answers "ok" with no JSON
	}
}
