package pointer

import (
	"context"
	"image"
	"image/color"
	"testing"
	"time"
)

func fill(w, h int, c color.Gray) *image.Gray {
	img := image.NewGray(image.Rect(0, 0, w, h))
	for i := range img.Pix {
		img.Pix[i] = c.Y
	}
	return img
}

func TestChanged(t *testing.T) {
	a := fill(200, 400, color.Gray{20})
	dot := fill(200, 400, color.Gray{20})
	for y := 100; y < 110; y++ { // a pointer-sized spot
		for x := 50; x < 60; x++ {
			dot.Pix[y*200+x] = 200
		}
	}
	if Changed(a, dot, 0.05) {
		t.Error("a pointer-sized change counted as a new screen")
	}
	if !Changed(a, fill(200, 400, color.Gray{230}), 0.05) {
		t.Error("a new screen not seen")
	}
}

// timedScreen hands out frames in order and records the capture time each Fresh asked for.
type timedScreen struct {
	frames []image.Image
	since  []time.Time
}

func (s *timedScreen) Live() bool                                                           { return true }
func (s *timedScreen) Frame() image.Image                                                   { return s.frames[0] }
func (s *timedScreen) Settled(context.Context, time.Duration, time.Duration, time.Duration) {}
func (s *timedScreen) Fresh(_ context.Context, since time.Time, _ time.Duration) image.Image {
	s.since = append(s.since, since)
	if len(s.since) >= len(s.frames) {
		return nil
	}
	return s.frames[len(s.since)]
}

func TestChangedSinceOnlyLooksAtFramesFromAfterTheLag(t *testing.T) {
	old, home := fill(200, 400, color.Gray{20}), fill(200, 400, color.Gray{230})
	s := &timedScreen{frames: []image.Image{old, old, old, home}}
	p := newPointer(t, &fakeDevice{}, s)
	sent := time.Now()
	if !p.changedSince(context.Background(), old, sent) {
		t.Fatal("the change in the third fresh frame was missed")
	}
	for i, since := range s.since {
		if since.Before(sent.Add(SettleLag)) {
			t.Fatalf("look %d asked for frames from %v after sending, before the %v lag", i, since.Sub(sent), SettleLag)
		}
	}
	s = &timedScreen{frames: []image.Image{old, old}}
	p = newPointer(t, &fakeDevice{}, s)
	if p.changedSince(context.Background(), old, time.Now()) {
		t.Fatal("a still screen counted as changed")
	}
	if ChangeWait != 5*time.Second {
		t.Fatalf("window %v", ChangeWait)
	}
}
