package daemon

import (
	"strings"
	"testing"
	"time"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/pointer"
)

// noteApp takes s.mu while Server.conn / devices / closeAll hold s.mu and then
// take c.mu, so onStatus must release c.mu before invoking the app callback.
func TestOnStatusNotifiesAfterReleasingConnMu(t *testing.T) {
	c := newConn("0123456789ab", "test", "")

	called := false
	c.onApp = func() {
		called = true
		acquired := make(chan struct{})
		go func() {
			c.mu.Lock()
			c.mu.Unlock()
			close(acquired)
		}()
		select {
		case <-acquired:
		case <-time.After(3 * time.Second):
			// Return so onStatus can release c.mu; blocking here would hang the test.
			t.Error("app callback ran while c.mu was still held")
		}
	}

	c.onStatus([]byte(`{"owner":"app","busy":1}`))
	if !called {
		t.Fatal("app callback was not invoked for owner: app")
	}
}

// #192: a pointer move StallAfter ago with no frame from AirPlay since is a stall; a missing vage is unknown.
func TestStalledVideo(t *testing.T) {
	c := newConn("0123456789ab", "test", "")
	moved := time.Now().Add(-5 * time.Second)
	c.lastMove = moved
	if _, ok := c.stalledNow(); ok {
		t.Fatal("no status yet: unknown, not stalled")
	}
	c.onStatus([]byte(`{"ap":"streaming","fz":0}`)) // firmware before vage in the compact status
	if _, ok := c.stalledNow(); ok {
		t.Fatal("no vage: unknown, not stalled")
	}
	c.onStatus([]byte(`{"ap":"streaming","fz":0,"vage":12000}`))
	if age, ok := c.stalledNow(); !ok || age < 11*time.Second {
		t.Fatalf("stalled = %v %v", age, ok)
	}
	if !strings.Contains(whyNotFound(c, moved, pointer.ErrNotFound).Error(), "video stale") {
		t.Fatal("pointer not found on a stalled stream must say the video is stale")
	}
	c.onStatus([]byte(`{"ap":"streaming","up":1}`)) // a later status without vage forgets the old one
	if _, ok := c.stalledNow(); ok {
		t.Fatal("vage from an older status was kept")
	}
	c.onStatus([]byte(`{"ap":"streaming","vage":3000}`)) // a frame came after the move
	if _, ok := c.stalledNow(); ok {
		t.Fatal("a frame after the move is not a stall")
	}
	c.onStatus([]byte(`{"ap":"streaming","vage":12000}`))
	c.lastMove = time.Now().Add(-2 * time.Second) // too recent to tell
	if _, ok := c.stalledNow(); ok {
		t.Fatal("a move 2 s ago is too recent to call a stall")
	}
	c.lastMove = moved
	c.captured = time.Now() // our own stream decoded a frame since
	if _, ok := c.stalledNow(); ok {
		t.Fatal("a decoded frame after the move is not a stall")
	}
	if err := whyNotFound(c, moved, pointer.ErrNotFound); err != pointer.ErrNotFound {
		t.Fatalf("not stalled: keep the pointer message, got %v", err)
	}
}
