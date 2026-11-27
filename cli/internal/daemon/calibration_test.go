package daemon

import (
	"os"
	"strings"
	"testing"
	"time"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/config"
)

// #194: each phone has its own calibration on a board; the board's old file goes to the first phone seen.
func TestCalibrationIsKeptPerPhone(t *testing.T) {
	dir := t.TempDir()
	c := newConn("246f28aa6ad5", "test", "")
	os.WriteFile(config.CalibrationPath(dir, c.ID), []byte(`{"w":400,"h":860,"moves":"axis"}`), 0o600)

	if p := c.pointer(dir); !p.Calibrated() { // phone not known yet: the board's file, as before
		t.Fatal("the board's calibration is not used while the phone is unknown")
	}
	c.onStatus([]byte(`{"ap":"streaming","src":"iPhone13,2"}`))
	if p := c.pointer(dir); !p.Calibrated() || p.Phone != "iPhone13,2" {
		t.Fatalf("the first phone did not take it over: %+v", p)
	}
	if _, err := os.Stat(config.PhoneCalibrationPath(dir, c.ID, "iPhone13,2")); err != nil {
		t.Fatal(err)
	}
	c.onStatus([]byte(`{"ap":"streaming","src":"iPhone18,1"}`))
	if p := c.pointer(dir); p.Calibrated() {
		t.Fatal("another phone uses the first one's calibration")
	}
	c.onStatus([]byte(`{"ap":"idle","src":""}`)) // mirroring stopped: keep the last phone's
	if p := c.pointer(dir); p.Phone != "iPhone18,1" {
		t.Fatalf("phone %q", p.Phone)
	}
	c.onStatus([]byte(`{"ap":"streaming","src":"iPhone13,2"}`))
	if p := c.pointer(dir); !p.Calibrated() {
		t.Fatal("back on the first phone: its calibration is gone")
	}
}

// #194: a tap nothing checked says so; the board's pacing is asked in the background, not before the tap.
func TestTapSaysItWasNotVerified(t *testing.T) {
	b := fakeBoard()
	b.Handle = func(cmd string) string {
		if cmd == "pace" {
			return "ok 3"
		}
		return "ok"
	}
	c, s := start(t, fakeTransport{b})
	call(t, c, Request{Cmd: "pair"})
	b.Status(`{"up":5000,"ap":"idle","w":480,"h":1040}`)
	time.Sleep(50 * time.Millisecond)
	os.WriteFile(config.CalibrationPath(s.Dir, "246f28aa6ad5"), []byte(`{"w":400,"h":860,"moves":"axis"}`), 0o600)
	r, data := call(t, c, Request{Cmd: "tap", Pts: []float64{240, 520}})
	if r.Status != "ok" || data["verified"] != false || !strings.Contains(data["message"].(string), "not verified") {
		t.Fatalf("tap: %+v", r)
	}
	time.Sleep(50 * time.Millisecond)
	if p := s.conns["246f28aa6ad5"].pointer(s.Dir); p.Pace != 0 && p.Pace != 3 || s.conns["246f28aa6ad5"].boardPace() != 3 {
		t.Fatalf("board pace %d", s.conns["246f28aa6ad5"].boardPace())
	}
}
