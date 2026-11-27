package pointer

import (
	"context"
	"encoding/json"
	"image"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// cornerScreen draws the fake device's pointer with a given span and the corner home really leaves it in.
type cornerScreen struct {
	d            *fakeDevice
	ox, oy       float64
	spanW, spanH float64
}

func (s *cornerScreen) at() (float64, float64) {
	s.d.mu.Lock()
	defer s.d.mu.Unlock()
	return s.ox + float64(s.d.x)/s.spanW, s.oy + float64(s.d.y)/s.spanH
}
func (s *cornerScreen) Live() bool { return true }
func (s *cornerScreen) Frame() image.Image {
	x, y := s.at()
	return frame(x*W, y*H)
}
func (s *cornerScreen) Settled(context.Context, time.Duration, time.Duration, time.Duration) {}
func (s *cornerScreen) Fresh(context.Context, time.Time, time.Duration) image.Image          { return s.Frame() }

// #194: home leaves the pointer at x ≈ 0.14 (the rounded corner); calibration fits it and taps land on target.
func TestCalibrationLearnsTheCornerOffset(t *testing.T) {
	d := &fakeDevice{}
	s := &cornerScreen{d: d, ox: 0.14, oy: 0.02, spanW: 586, spanH: 1277}
	p := newPointer(t, d, s)
	if err := p.Calibrate(context.Background()); err != nil {
		t.Fatal(err)
	}
	if math.Abs(p.Origin[0]-0.14) > 0.01 || math.Abs(p.Origin[1]-0.02) > 0.01 {
		t.Fatalf("origin %v", p.Origin)
	}
	for _, target := range []float64{0.2, 0.5, 0.8} {
		p.Point(context.Background(), target, target, false)
		if x, y := s.at(); math.Abs(x-target) > 0.01 || math.Abs(y-target) > 0.01 {
			t.Fatalf("aimed at %.1f, landed at %.3f, %.3f", target, x, y)
		}
	}
	if again := New(d, s, p.file); again.Origin != p.Origin || again.Stale() != "" {
		t.Fatalf("reloaded origin %v, stale %q", again.Origin, again.Stale())
	}
}

// The app's calibration file (no "moves") loads with its origin: the +82 px / +25 px of the issue are gone.
func TestTheAppsCalibrationFileLoads(t *testing.T) {
	file := filepath.Join(t.TempDir(), "calibration.json")
	os.WriteFile(file, []byte(`{"w":586,"h":1277,"seen":{"x":[],"y":[]},"quality":0.021,"aspect":0.46,"v":4,"pace":1,"ox":0.14,"oy":0.02,"gain":[[5,0.8]]}`), 0o600)
	p := New(&fakeDevice{}, nil, file)
	if !p.Calibrated() || p.Pace != 1 || len(p.Gain) != 1 {
		t.Fatalf("loaded %+v", p)
	}
	if dx, dy := p.dx(0.5), p.dy(0.5); dx != 211 || dy != 613 {
		t.Fatalf("target 0.5 -> dx %d dy %d, the app sends 211 613", dx, dy)
	}
}

func TestSpeedGainLengthensShortMoves(t *testing.T) {
	p := newPointer(t, &fakeDevice{}, nil)
	if x, _ := p.paced(5, 0); x != 5 {
		t.Fatalf("no gain: %d", x)
	}
	p.Gain = [][2]float64{{5, 0.8}}
	if x, _ := p.paced(5, 0); x <= 5 {
		t.Fatalf("a short move at a slower speed falls short and must be sent longer: %d", x)
	}
	if x, _ := p.paced(200, 0); x != 200 {
		t.Fatalf("a long move goes at full speed: %d", x)
	}
}

// The app's invalidation rules: a bad check, another pacing, another screen shape, drift.
func TestStaleCalibration(t *testing.T) {
	d := &fakeDevice{}
	p := newPointer(t, d, &cornerScreen{d: d, spanW: 400, spanH: 800}) // frames 498 x 1080: aspect 0.461
	p.FinishCalibration(0.5, 0.25)
	if why := p.Stale(); why != "" {
		t.Fatalf("fresh calibration stale: %s", why)
	}
	pace := 0
	p.BoardPace = func() int { return pace }
	pace = 3
	if p.Stale() != "" || p.Pace != 3 {
		t.Fatalf("a calibration from before the pace was known takes the board's: pace %d", p.Pace)
	}
	pace = 2
	if !strings.Contains(p.Stale(), "pacing") {
		t.Fatal("another pacing must calibrate again")
	}
	pace = 3
	q := 0.1435 // the issue's stored calibration
	p.Quality = &q
	if !strings.Contains(p.Stale(), "14.3%") {
		t.Fatalf("a 14%% check: %q", p.Stale())
	}
	p.Quality = nil
	a := 0.40
	p.Aspect = &a
	if !strings.Contains(p.Stale(), "shape") {
		t.Fatal("another screen shape must calibrate again")
	}
	p.Aspect = nil
	for _, aimed := range []float64{0.2, 0.5, 0.8} {
		p.remember("x", [2]float64{aimed, aimed + 0.02})
	}
	if !strings.Contains(p.Stale(), "drifted") {
		t.Fatal("drift over 1.5% must calibrate again")
	}
}

func TestRestoreKeepsThePreviousCalibration(t *testing.T) {
	p := newPointer(t, &fakeDevice{}, nil)
	p.FinishCalibration(0.5, 0.25)
	snap := p.Snapshot()
	p.FinishCalibration(0.25, 0.25)
	p.Restore(snap)
	if *p.Span != (Span{400, 800}) || *New(&fakeDevice{}, nil, p.file).Span != (Span{400, 800}) {
		t.Fatalf("span %+v", p.Span)
	}
	p.Restore(nil)
	if p.Calibrated() || New(&fakeDevice{}, nil, p.file).Calibrated() {
		t.Fatal("restoring no calibration keeps one")
	}
}

// #194: an aimed tap that cannot see the pointer is not sent and says so.
func TestAimedTapWithoutThePointerIsNotSent(t *testing.T) {
	d := &fakeDevice{}
	p := newPointer(t, d, &blankScreen{})
	p.FinishCalibration(0.5, 0.25)
	if err := p.Tap(context.Background(), 0.5, 0.5, true, 1); err != ErrAimNotFound {
		t.Fatalf("err %v", err)
	}
	for _, s := range d.sent {
		if s == "click" {
			t.Fatalf("clicked: %v", d.sent)
		}
	}
}

// A board's calibration from before (CLI 0.1.4) is taken over by the first phone only.
func TestLegacyCalibrationIsAdoptedOnce(t *testing.T) {
	dir := t.TempDir()
	legacy := filepath.Join(dir, "calibration-b.json")
	os.WriteFile(legacy, []byte(`{"w":400,"h":860,"moves":"axis"}`), 0o600)
	a := New(&fakeDevice{}, nil, filepath.Join(dir, "calibration-b-iPhone13-2.json"))
	a.Phone = "iPhone13,2"
	if !a.Adopt(legacy) || *New(&fakeDevice{}, nil, a.file).Span != (Span{400, 860}) {
		t.Fatal("the first phone did not take it over")
	}
	var m map[string]any
	raw, _ := os.ReadFile(legacy)
	if json.Unmarshal(raw, &m); m["rekeyed"] != "iPhone13,2" || m["moves"] != "axis" {
		t.Fatalf("legacy file now %s", raw)
	}
	if !New(&fakeDevice{}, nil, legacy).Calibrated() {
		t.Fatal("CLI 0.1.4 can no longer read its file")
	}
	b := New(&fakeDevice{}, nil, filepath.Join(dir, "calibration-b-iPhone18-1.json"))
	if b.Adopt(legacy) || b.Calibrated() {
		t.Fatal("a second phone took over the first one's calibration")
	}
}
