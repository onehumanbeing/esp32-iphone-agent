package daemon

import (
	"image"
	"log"
	"math"
	"strings"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/history"
)

func (s *Server) recorder() *history.Recorder {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.hist == nil {
		s.hist = &history.Recorder{Dir: history.Root(s.Dir)}
	}
	return s.hist
}

// recordShot keeps the screen an agent looked at, as the app keeps what its model saw ("llm" records).
func (s *Server) recordShot(img image.Image, w, h int) {
	if err := s.recorder().Write("llm", map[string]any{"role": "screenshot", "width": w, "height": h}, history.Thumb(img, 0)); err != nil {
		log.Printf("history: %v", err)
	}
}

// recordAction writes one io command as the app's action, in 0-1000 screen units.
func (s *Server) recordAction(c *Conn, req Request, err error) {
	rec := map[string]any{}
	unit := func(v, size float64) int { return int(math.Round(v / size * 1000)) }
	w, h, serr := c.size()
	pts := len(req.Pts)
	switch req.Cmd {
	case "tap", "longpress":
		if serr != nil || pts < 2 {
			return
		}
		rec["action"], rec["x"], rec["y"] = req.Cmd, unit(req.Pts[0], w), unit(req.Pts[1], h)
		if req.Cmd == "longpress" {
			rec["ms"] = req.Ms
		}
	case "swipe":
		if serr != nil || pts < 4 {
			return
		}
		rec["action"] = "swipe"
		rec["x1"], rec["y1"], rec["x2"], rec["y2"] = unit(req.Pts[0], w), unit(req.Pts[1], h), unit(req.Pts[2], w), unit(req.Pts[3], h)
	case "text":
		rec["action"], rec["text"] = "type", req.Text
	case "keys":
		rec["action"], rec["combo"] = "key", strings.ToLower(req.Text)
	case "button":
		rec["action"] = "home"
		if !strings.EqualFold(req.Text, "HOME") {
			rec["action"], rec["button"] = "button", req.Text
		}
	default:
		return
	}
	if err != nil {
		rec["error"] = err.Error()
	}
	if werr := s.recorder().Write("step", rec, nil); werr != nil {
		log.Printf("history: %v", werr)
	}
}
