package history

import (
	"errors"
	"path/filepath"
	"time"
)

// Replayable are the moves the app repeats blindly (Replay.swift).
var Replayable = map[string]bool{"tap": true, "swipe": true, "type": true, "home": true, "back": true, "key": true, "wait": true}

// Summary is one run in `history list`.
type Summary struct {
	ID          string `json:"id"`
	Start       string `json:"start"`
	Steps       int    `json:"steps"`
	Screenshots int    `json:"screenshots"`
	Outcome     string `json:"outcome"`
	Task        string `json:"task,omitempty"`
}

// Step is one action of a run with the screen it was done on (the last screenshot before it), as the app's
// RunStore.load pairs them.
type Step struct {
	Step   int            `json:"step"` // 1-based, what `intent save --steps` takes
	T      float64        `json:"t"`
	Action map[string]any `json:"action"`
	Error  string         `json:"error,omitempty"`
	Frame  string         `json:"frame,omitempty"` // file in the run folder
}

// Replayable: a move the app can repeat, and it worked.
func (s Step) Replayable() bool {
	name, _ := s.Action["action"].(string)
	return s.Error == "" && Replayable[name]
}

// JSON is the action as the app stores it (RecordedStep.action).
func (s Step) JSON() string { return JSON(s.Action) }

// JSON is an object written as the app's PyJSON.dumps writes it.
func JSON(m map[string]any) string {
	b, _ := marshal(m)
	return string(b)
}

// Run is a parsed run.
type Run struct {
	ID    string `json:"id"`
	Dir   string `json:"dir"`
	Task  string `json:"task,omitempty"`
	Start string `json:"start"`
	Steps []Step `json:"steps"`
	shots int
	last  float64 // t of the last record
}

var meta = map[string]bool{"n": true, "t": true, "kind": true, "frame": true, "error": true}

// Load reads one run; id "latest" (or "") is the newest.
func Load(root, id string) (*Run, error) {
	if id == "" || id == "latest" {
		ids, err := IDs(root)
		if err != nil {
			return nil, err
		}
		if len(ids) == 0 {
			return nil, errors.New("no runs yet: actions and screenshots are recorded as they happen")
		}
		id = ids[0]
	}
	recs, err := Read(root, id)
	if err != nil {
		return nil, err
	}
	r := &Run{ID: id, Dir: filepath.Join(root, id), Start: start(id), Steps: []Step{}}
	frame := ""
	for _, rec := range recs {
		if t, ok := rec["t"].(float64); ok {
			r.last = max(r.last, t)
		}
		if f := rec.Str("frame"); f != "" {
			frame = f
			r.shots++
		}
		switch rec.Str("kind") {
		case "task":
			r.Task = rec.Str("task")
		case "step":
			act := map[string]any{}
			for k, v := range rec {
				if !meta[k] {
					act[k] = v
				}
			}
			t, _ := rec["t"].(float64)
			r.Steps = append(r.Steps, Step{Step: len(r.Steps) + 1, T: t, Action: act, Error: rec.Str("error"), Frame: frame})
		}
	}
	return r, nil
}

func start(id string) string {
	if len(id) >= len(Layout) {
		if t, err := time.ParseInLocation(Layout, id[:len(Layout)], time.Local); err == nil {
			return t.Format(time.RFC3339)
		}
	}
	return ""
}

// Outcome: the app's words when the run ended with done/fail/stopped, else active, failed (last step erred) or ended.
func (r *Run) Outcome(now time.Time) string {
	if len(r.Steps) == 0 {
		if r.active(now) {
			return "active"
		}
		return "empty"
	}
	last := r.Steps[len(r.Steps)-1]
	switch last.Action["action"] {
	case "done":
		return "done"
	case "fail":
		return "failed"
	case "stopped":
		return "stopped"
	}
	if r.active(now) {
		return "active"
	}
	if last.Error != "" {
		return "failed"
	}
	return "ended"
}

func (r *Run) active(now time.Time) bool { return now.Sub(unix(r.last)) <= Idle }

// List summarizes the newest runs.
func List(root string, limit int) ([]Summary, error) {
	ids, err := IDs(root)
	if err != nil {
		return nil, err
	}
	out := []Summary{}
	for i, id := range ids {
		if len(out) == limit {
			break
		}
		r, err := Load(root, id)
		if err != nil {
			continue
		}
		outcome := r.Outcome(time.Now())
		if i > 0 && outcome == "active" { // only the newest run is still going
			outcome = "ended"
		}
		out = append(out, Summary{ID: id, Start: r.Start, Steps: len(r.Steps), Screenshots: r.shots, Outcome: outcome, Task: r.Task})
	}
	return out, nil
}
