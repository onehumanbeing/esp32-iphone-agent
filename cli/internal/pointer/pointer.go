// Package pointer turns screen positions into the board's relative mouse moves. Port of the iOS app's
// Pointer.swift (itself a port of phone.py).
//
// The pointer is relative, so we track where it is (in mouse units) and move from there; every few gestures it
// is slammed into the top-left corner (`home`) again to cancel drift. Coordinates are fractions of the screen
// (0..1, origin top-left), so they work for any frame size.
package pointer

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"math"
	"os"
	"strings"
	"time"
)

const (
	CalibrationMove = 200                    // mouse units moved diagonally for a one-point calibration
	RehomeEvery     = 10                     // gestures between re-homing
	Hold            = 250 * time.Millisecond // rest before lifting, so iOS adds no momentum
	TapGap          = 150 * time.Millisecond // stay still after a click, so iOS sees a finished tap
	Nudge           = 12                     // mouse units the pointer is wiggled by to find it on screen
	AimTolerance    = 0.008                  // screen fraction; a bigger miss is corrected before pressing
	MaxMiss         = 0.06                   // bigger misses are still corrected, but not learned from
	SettleLag       = 300 * time.Millisecond // after a key, frames captured sooner still show the old screen
	ChangeWait      = 5 * time.Second        // how long GoHome watches for the screen to change
)

// CalibrationStops are the distances at which calibration finds the pointer.
var CalibrationStops = []int{150, 350}

// Device sends one board command; an "err" reply is an error. Links counts (re)connections.
type Device interface {
	Send(ctx context.Context, line string) error
	Links() int
}

// Screen is the mirrored screen.
type Screen interface {
	Live() bool
	Frame() image.Image
	// Settled waits until the image stopped changing for `quiet` (at least `least`, at most `most`).
	Settled(ctx context.Context, quiet, least, most time.Duration)
	// Fresh returns the first frame captured after `since`, nil if none within timeout.
	Fresh(ctx context.Context, since time.Time, timeout time.Duration) image.Image
}

type Span struct{ W, H int }

type saved struct {
	W       int                    `json:"w"`
	H       int                    `json:"h"`
	Seen    map[string][][]float64 `json:"seen,omitempty"`
	Quality *float64               `json:"quality,omitempty"`
	Aspect  *float64               `json:"aspect,omitempty"`
}

type Pointer struct {
	dev    Device
	screen Screen
	file   string
	Span   *Span // mouse units needed to cross the full screen width / height
	pos    *[2]int
	moves  int
	link   int
	// where the pointer really landed (seen on screen) for the fraction aimed at, per axis; a line fit through
	// them corrects every later move, so taps get better as the agent works
	seen    map[string][][2]float64
	Quality *float64 // pointer error at the last check, fraction of the screen
	Aspect  *float64 // frame width / height when calibrated
	Log     func(string)
	Sleep   func(context.Context, time.Duration) error
}

func sleep(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// New loads a saved calibration from file, if any. screen may be nil.
func New(dev Device, screen Screen, file string) *Pointer {
	p := &Pointer{dev: dev, screen: screen, file: file, seen: map[string][][2]float64{"x": nil, "y": nil},
		Log: func(string) {}, Sleep: sleep}
	raw, err := os.ReadFile(file)
	var s saved
	if err != nil || json.Unmarshal(raw, &s) != nil || s.W <= 0 || s.H <= 0 {
		return p
	}
	p.Span = &Span{s.W, s.H}
	p.Quality, p.Aspect = s.Quality, s.Aspect
	for _, axis := range []string{"x", "y"} {
		for _, v := range s.Seen[axis] {
			if len(v) == 2 {
				p.remember(axis, [2]float64{v[0], v[1]})
			}
		}
	}
	return p
}

func (p *Pointer) Calibrated() bool { return p.Span != nil }

// Forget makes the position unknown (someone else moved the pointer): the next gesture homes first.
func (p *Pointer) Forget() { p.pos = nil }

func (p *Pointer) remember(axis string, sample [2]float64) {
	s := append(p.seen[axis], sample)
	if len(s) > 12 { // deque(maxlen=12)
		s = s[len(s)-12:]
	}
	p.seen[axis] = s
}

// send runs one command; after a failed one the pointer position is unknown (the next gesture homes first).
func (p *Pointer) send(ctx context.Context, format string, a ...any) error {
	err := p.dev.Send(ctx, fmt.Sprintf(format, a...))
	if err != nil {
		p.pos = nil
	}
	return err
}

func (p *Pointer) screenAspect() float64 {
	if p.screen != nil {
		if f := p.screen.Frame(); f != nil && f.Bounds().Dy() > 0 {
			return float64(f.Bounds().Dx()) / float64(f.Bounds().Dy())
		}
	}
	return 9 / 19.5
}

// ErrNotFound: calibration could not see the pointer on screen.
var ErrNotFound = errors.New("calibration: pointer not found on screen (is the mouse pointer visible, AssistiveTouch on, Screen Mirroring on?)")

// Calibrate finds the pointer on screen at two known distances from the corner and fits the mapping from both.
func (p *Pointer) Calibrate(ctx context.Context) error {
	p.pos = nil
	if err := p.send(ctx, "home"); err != nil {
		return err
	}
	type stop struct {
		units int
		x, y  float64
	}
	var found []stop
	for _, units := range CalibrationStops {
		step := units
		if len(found) > 0 {
			step = units - found[len(found)-1].units
		}
		if err := p.send(ctx, "move %d %d", step, step); err != nil {
			return err
		}
		if p.screen == nil || !p.screen.Live() {
			break
		}
		pt, ok, err := p.findPointer(ctx)
		if err != nil {
			return err
		}
		if !ok {
			break
		}
		found = append(found, stop{units, pt.X, pt.Y})
	}
	if len(found) < 2 {
		return ErrNotFound
	}
	a, b := found[0], found[1]
	if b.x == a.x || b.y == a.y {
		return ErrNotFound
	}
	s := Span{int(math.RoundToEven(float64(b.units-a.units) / (b.x - a.x))), int(math.RoundToEven(float64(b.units-a.units) / (b.y - a.y)))}
	if s.W <= 0 || s.H <= 0 {
		return ErrNotFound
	}
	p.Span = &s
	aspect := p.screenAspect()
	p.Quality, p.Aspect = nil, &aspect
	p.seen = map[string][][2]float64{"x": nil, "y": nil}
	for _, f := range found { // where each stop landed, so moves are corrected for the offset too
		p.remember("x", [2]float64{float64(f.units) / float64(s.W), f.x})
		p.remember("y", [2]float64{float64(f.units) / float64(s.H), f.y})
	}
	p.Log(fmt.Sprintf("calibration: span %d x %d", s.W, s.H))
	return p.save()
}

// findPointer wiggles the pointer and finds it anywhere on screen (the span may still be unknown).
func (p *Pointer) findPointer(ctx context.Context) (Point, bool, error) {
	p.screen.Settled(ctx, 200*time.Millisecond, 300*time.Millisecond, 1500*time.Millisecond)
	before, sent := p.screen.Frame(), time.Now()
	if err := p.send(ctx, "move %d 0", Nudge); err != nil {
		return Point{}, false, err
	}
	after := p.screen.Fresh(ctx, sent, time.Second)
	if after != nil {
		p.screen.Settled(ctx, 150*time.Millisecond, 100*time.Millisecond, 600*time.Millisecond)
		after = p.screen.Frame()
	}
	if err := p.send(ctx, "move -%d 0", Nudge); err != nil {
		return Point{}, false, err
	}
	pt, ok := Locate(before, after, Point{0.5, 0.5}, 0.025, Point{0.5, 0.5})
	if !ok || pt.X <= 0.03 || pt.X >= 0.97 || pt.Y <= 0.03 || pt.Y >= 0.97 {
		return Point{}, false, nil
	}
	return pt, true, nil
}

// FinishCalibration: x, y is where the pointer ended up after `home` + `move 200 200` (one point).
func (p *Pointer) FinishCalibration(x, y float64) error {
	aspect := p.screenAspect()
	p.Quality, p.Aspect = nil, &aspect
	p.Span = &Span{int(math.RoundToEven(CalibrationMove / x)), int(math.RoundToEven(CalibrationMove / y))}
	p.seen = map[string][][2]float64{"x": nil, "y": nil}
	return p.save()
}

// save keeps the calibration plus the observed landings, so the correction survives a restart.
func (p *Pointer) save() error {
	if p.Span == nil || p.file == "" {
		return nil
	}
	s := saved{W: p.Span.W, H: p.Span.H, Seen: map[string][][]float64{}, Quality: p.Quality, Aspect: p.Aspect}
	for axis, pts := range p.seen {
		s.Seen[axis] = [][]float64{}
		for _, v := range pts {
			s.Seen[axis] = append(s.Seen[axis], []float64{v[0], v[1]})
		}
	}
	raw, _ := json.Marshal(s)
	return os.WriteFile(p.file, raw, 0o600)
}

// ErrNotCalibrated: run Calibrate first.
var ErrNotCalibrated = errors.New("pointer not calibrated")

// Point moves the pointer to x, y. aim: find it on screen afterwards and fix a miss (slower).
func (p *Pointer) Point(ctx context.Context, x, y float64, aim bool) error {
	if !p.Calibrated() {
		return ErrNotCalibrated
	}
	if err := p.moveTo(ctx, p.dx(x), p.dy(y), true); err != nil {
		return err
	}
	if aim && p.screen != nil {
		return p.aim(ctx, x, y)
	}
	return nil
}

// aim is the closed loop: find the real pointer on screen, fix a miss, and learn the error for later moves.
func (p *Pointer) aim(ctx context.Context, x, y float64) error {
	found, ok, err := p.measure(ctx, x, y)
	if err != nil {
		return err
	}
	if !ok {
		p.Log(fmt.Sprintf("aim (%.3f, %.3f): pointer not found", x, y))
		return nil
	}
	if math.Max(math.Abs(found.X-x), math.Abs(found.Y-y)) <= MaxMiss { // learn from normal drift only
		p.remember("x", [2]float64{p.Fix(x, "x"), found.X})
		p.remember("y", [2]float64{p.Fix(y, "y"), found.Y})
		p.save()
	}
	if math.Abs(found.X-x) <= AimTolerance && math.Abs(found.Y-y) <= AimTolerance {
		return nil
	}
	mx := int(math.RoundToEven((x - found.X) * float64(p.Span.W)))
	my := int(math.RoundToEven((y - found.Y) * float64(p.Span.H)))
	if err := p.send(ctx, "move %d %d", mx, my); err != nil { // fix this miss right away
		return err
	}
	if p.pos != nil {
		p.pos = &[2]int{p.pos[0] + mx, p.pos[1] + my}
	}
	return nil
}

// measure wiggles the pointer and finds it on screen, near the target first, then anywhere.
func (p *Pointer) measure(ctx context.Context, x, y float64) (Point, bool, error) {
	if p.screen == nil || p.Span == nil {
		return Point{}, false, nil
	}
	nudge := Nudge
	if x >= 0.9 { // stay clear of the screen edge
		nudge = -Nudge
	}
	p.screen.Settled(ctx, 150*time.Millisecond, 100*time.Millisecond, 600*time.Millisecond) // pointer at rest
	before, sent := p.screen.Frame(), time.Now()
	if err := p.send(ctx, "move %d 0", nudge); err != nil {
		return Point{}, false, err
	}
	after := p.screen.Fresh(ctx, sent, 1200*time.Millisecond)
	if after != nil {
		p.screen.Settled(ctx, 100*time.Millisecond, 50*time.Millisecond, 400*time.Millisecond)
		after = p.screen.Frame()
	}
	if err := p.send(ctx, "move %d 0", -nudge); err != nil {
		return Point{}, false, err
	}
	shift := float64(nudge) / float64(p.Span.W)
	if pt, ok := Locate(before, after, Point{x, y}, shift, Point{0.12, 0.08}); ok {
		return pt, true, nil
	}
	pt, ok := Locate(before, after, Point{0.5, 0.5}, shift, Point{0.5, 0.5})
	return pt, ok, nil
}

// Verify moves to a known point and measures the miss (fraction of the screen); ok=false: pointer not found.
func (p *Pointer) Verify(ctx context.Context, x, y float64) (float64, bool, error) {
	if err := p.Point(ctx, x, y, false); err != nil {
		return 0, false, err
	}
	found, ok, err := p.measure(ctx, x, y)
	if err != nil || !ok {
		return 0, false, err
	}
	e := math.Max(math.Abs(found.X-x), math.Abs(found.Y-y))
	p.Quality = &e
	return e, true, p.save()
}

// Drift is how far the learned correction has moved targets away from the plain calibration.
func (p *Pointer) Drift() float64 {
	d := 0.0
	for _, t := range []float64{0.2, 0.8} {
		for _, axis := range []string{"x", "y"} {
			d = math.Max(d, math.Abs(p.Fix(t, axis)-t))
		}
	}
	return d
}

// Fix is the fraction to aim at so the pointer lands on t, from the line through the observed landings.
func (p *Pointer) Fix(t float64, axis string) float64 {
	pts := p.seen[axis]
	if len(pts) < 2 {
		return t
	}
	n := float64(len(pts))
	mc, mf := 0.0, 0.0
	for _, v := range pts {
		mc += v[0] / n
		mf += v[1] / n
	}
	variance, cov := 0.0, 0.0
	for _, v := range pts {
		variance += (v[0] - mc) * (v[0] - mc)
		cov += (v[0] - mc) * (v[1] - mf)
	}
	a := 1.0 // landed = a*aimed + b
	if variance > 1e-4 {
		a = cov / variance
	}
	if a <= 0.85 || a >= 1.15 {
		a = 1
	}
	b := mf - a*mc
	if math.Abs(b) < 0.1 {
		return (t - b) / a
	}
	return t
}

func (p *Pointer) moveTo(ctx context.Context, tx, ty int, rehome bool) error {
	if l := p.dev.Links(); p.link != l { // new link: a dropped gesture may have left the button down
		if err := p.send(ctx, "release"); err != nil {
			return err
		}
		p.pos, p.link = nil, l
	}
	if p.pos == nil || rehome && p.moves >= RehomeEvery {
		if err := p.send(ctx, "home"); err != nil {
			return err
		}
		p.pos, p.moves = &[2]int{0, 0}, 0
	}
	x, y := p.pos[0], p.pos[1]
	p.pos = nil // unknown until the move succeeds
	if err := p.send(ctx, "move %d %d", tx-x, ty-y); err != nil {
		return err
	}
	p.pos, p.moves = &[2]int{tx, ty}, p.moves+1
	return nil
}

// Reset lets go of the button and re-homes the pointer, whatever state a gesture left.
func (p *Pointer) Reset(ctx context.Context) error {
	p.pos = nil
	if err := p.send(ctx, "release"); err != nil {
		return err
	}
	if err := p.send(ctx, "home"); err != nil {
		return err
	}
	p.pos, p.moves = &[2]int{0, 0}, 0
	return nil
}

// Tap clicks count times (at least once) at x, y without moving in between: 2 is a double tap.
func (p *Pointer) Tap(ctx context.Context, x, y float64, aim bool, count int) error {
	if err := p.Point(ctx, x, y, aim); err != nil {
		return err
	}
	for i := 0; i < max(count, 1); i++ {
		if err := p.send(ctx, "click"); err != nil {
			return err
		}
	}
	return p.Sleep(ctx, TapGap)
}

// LongPress presses at x, y for d without moving.
func (p *Pointer) LongPress(ctx context.Context, x, y float64, d time.Duration) error {
	if err := p.Point(ctx, x, y, false); err != nil {
		return err
	}
	if err := p.send(ctx, "press"); err != nil {
		return err
	}
	err := p.Sleep(ctx, d)
	if rerr := p.send(context.WithoutCancel(ctx), "release"); err == nil {
		err = rerr
	}
	return err
}

func (p *Pointer) Swipe(ctx context.Context, x1, y1, x2, y2 float64, hold bool) error {
	return p.Drag(ctx, []Point{{x1, y1}, {x2, y2}}, hold)
}

// Drag presses at the first point, moves through the rest, releases: one continuous stroke. hold rests at the
// end first, so lists and pickers stop exactly there; system gestures (home, back) need the flick.
func (p *Pointer) Drag(ctx context.Context, pts []Point, hold bool) error {
	if err := p.Point(ctx, pts[0].X, pts[0].Y, false); err != nil {
		return err
	}
	if err := p.send(ctx, "press"); err != nil {
		return err
	}
	err := func() error {
		for _, pt := range pts[1:] {
			if err := p.moveTo(ctx, p.dx(pt.X), p.dy(pt.Y), false); err != nil { // never home mid-drag
				return err
			}
		}
		if hold {
			return p.Sleep(ctx, Hold)
		}
		return nil
	}()
	if rerr := p.send(context.WithoutCancel(ctx), "release"); err == nil {
		err = rerr
	}
	return err
}

// Type types text as the board can (see Typeable).
func (p *Pointer) Type(ctx context.Context, text string) (string, error) {
	ascii := Typeable(text)
	if ascii == "" {
		return "", errors.New("nothing typeable in that text (the board types ASCII only)")
	}
	// Spaces go as their own key: inside a `type` line iOS dropped every one ("coffee near East Broadway" came
	// out "coffeenearEastBroadway" in Maps, 2026-10-21), while a separate space key always landed.
	for i, word := range strings.Split(ascii, " ") {
		if i > 0 {
			if err := p.Key(ctx, "space"); err != nil {
				return ascii, err
			}
		}
		if word == "" {
			continue
		}
		if err := p.send(ctx, "type %s", word); err != nil {
			return ascii, err
		}
	}
	return ascii, nil
}

func (p *Pointer) Key(ctx context.Context, combo string) error { return p.send(ctx, "key %s", combo) }

// GoHome goes to the Home Screen like the app's leaveApp: the consumer-control Home key, then Cmd+H, then the flick
// up from the home bar, each until the screen really changes. The board acknowledges a key iOS ignores (seen on
// an iPhone in a video app, 2026-10-21), so an "ok" alone proves nothing; without video the key's "ok" is all there is.
func (p *Pointer) GoHome(ctx context.Context) error {
	tries := []func() error{
		func() error { return p.send(ctx, "homescreen") },
		func() error { return p.Key(ctx, "cmd+h") },
		func() error {
			if !p.Calibrated() {
				if err := p.Calibrate(ctx); err != nil {
					return err
				}
			}
			return p.HomeSwipe(ctx)
		},
	}
	var last error
	for i, try := range tries {
		before, sent := p.frame(), time.Now()
		err := try()
		if err != nil && strings.HasPrefix(err.Error(), "busy") {
			return err
		}
		if err == nil && before == nil && i != 1 {
			return nil // no video to check against: trust the Home key, and after Cmd+H still flick (as before)
		}
		if err == nil && before != nil && p.changedSince(ctx, before, sent) {
			return nil
		}
		last = err
	}
	if last != nil {
		return last
	}
	return errors.New("the Home Screen did not come up (Home key, Cmd+H and the swipe up all left the screen as it was)")
}

func (p *Pointer) frame() image.Image {
	if p.screen == nil || !p.screen.Live() {
		return nil
	}
	return p.screen.Frame()
}

// changedSince: a frame captured at least SettleLag after `sent` differs from before in more than a sliver (the
// pointer alone is not it). Frames from the first SettleLag still show the old screen, and over BLE the picture
// lags the phone and the Home Screen animation starts late: one look after 1.5 s, and later a 3 s window, missed
// it and the next fallback ran on top (2026-10-21). So: board capture time >= sent+SettleLag, for up to ChangeWait.
func (p *Pointer) changedSince(ctx context.Context, before image.Image, sent time.Time) bool {
	deadline := sent.Add(ChangeWait)
	for since := sent.Add(SettleLag); time.Now().Before(deadline); since = later(since, time.Now()) {
		f := p.screen.Fresh(ctx, since, time.Until(deadline))
		if f == nil {
			return false
		}
		if Changed(before, f, 0.05) {
			return true
		}
	}
	return false
}

func later(a, b time.Time) time.Time {
	if a.After(b) {
		return a
	}
	return b
}

// HomeSwipe is a real home-bar flick (a flick, not a rest: resting opens the app switcher).
func (p *Pointer) HomeSwipe(ctx context.Context) error {
	defer func() { p.pos = nil }() // edge clamping invalidates the tracked position
	return p.Swipe(ctx, 0.5, 0.995, 0.5, 0.15, false)
}

func (p *Pointer) dx(x float64) int {
	return int(math.RoundToEven(math.Min(math.Max(p.Fix(x, "x"), 0), 1) * float64(p.Span.W)))
}

func (p *Pointer) dy(y float64) int {
	return int(math.RoundToEven(math.Min(math.Max(p.Fix(y, "y"), 0), 1) * float64(p.Span.H)))
}
