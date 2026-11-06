package audio

import (
	"fmt"
	"strings"
	"sync"
	"time"
)

// Heard is one segment of sound and its words.
type Heard struct {
	Start, End time.Time // End zero while it goes on; Start == End when only the end is known (the app's lines)
	Text       string
	Final      bool // transcribed (Text "" then means no words)
}

// Within is how far back `listen` looks.
const Within = 30 * time.Second

// Block is the Heard text for the agent, in the app's wording (ios/IPhoneAgent/Audio/AudioFeed.swift); "" if
// nothing was heard in the window. how says how the words were made.
func Block(now time.Time, items []Heard, how string) string {
	var lines []string
	for _, h := range items {
		end := h.End
		if end.IsZero() {
			end = now
		}
		if now.Sub(end) > Within {
			continue
		}
		var when string
		switch {
		case h.End.IsZero():
			when = fmt.Sprintf("now, %d s so far", secs(now.Sub(h.Start)))
		case h.Start.Equal(h.End):
			when = fmt.Sprintf("%d s ago", secs(now.Sub(h.End)))
		default:
			when = fmt.Sprintf("%d s ago, %d s long", secs(now.Sub(h.End)), secs(h.End.Sub(h.Start)))
		}
		words := fmt.Sprintf("%q", truncate(h.Text, 400))
		switch {
		case h.Text == "" && h.Final:
			words = "(sound, no words recognized)"
		case h.Text == "":
			words = "(sound, still transcribing)"
		}
		lines = append(lines, "- "+when+": "+words)
	}
	if len(lines) == 0 {
		return ""
	}
	return fmt.Sprintf("Heard (phone audio, last %d s; %s):\n%s", secs(Within), how, strings.Join(lines, "\n"))
}

func secs(d time.Duration) int { return int(d.Round(time.Second) / time.Second) }

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && s[n]&0xC0 == 0x80 {
		n--
	}
	return s[:n]
}

// Recent keeps the last minute of segments transcribed here (raw mode).
type Recent struct {
	mu    sync.Mutex
	items []Heard
}

const keep = time.Minute

// Begin notes a segment going on.
func (r *Recent) Begin(start time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.prune(start)
	if n := len(r.items); n > 0 && r.items[n-1].End.IsZero() {
		return
	}
	r.items = append(r.items, Heard{Start: start})
}

// End closes the segment that started at start.
func (r *Recent) End(start, end time.Time) {
	r.set(start, func(h *Heard) { h.End = end })
}

// Done gives that segment its words.
func (r *Recent) Done(start time.Time, text string) {
	r.set(start, func(h *Heard) { h.Text, h.Final = text, true })
}

func (r *Recent) set(start time.Time, f func(*Heard)) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for i := range r.items {
		if r.items[i].Start.Equal(start) {
			f(&r.items[i])
			return
		}
	}
}

// Items is a copy of the kept segments, oldest first.
func (r *Recent) Items() []Heard {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]Heard(nil), r.items...)
}

func (r *Recent) prune(now time.Time) {
	i := 0
	for i < len(r.items) && !r.items[i].End.IsZero() && now.Sub(r.items[i].End) > keep {
		i++
	}
	r.items = r.items[i:]
}
