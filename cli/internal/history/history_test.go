package history

import (
	"encoding/json"
	"image"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type clock struct{ t time.Time }

func (c *clock) now() time.Time { return c.t }

func TestRecordsInTheAppsTraceFormat(t *testing.T) {
	root := t.TempDir()
	c := &clock{time.Date(2025, 10, 21, 9, 30, 0, 0, time.Local)}
	r := &Recorder{Dir: root, Now: c.now}
	if err := r.Write("llm", map[string]any{"role": "screenshot"}, Thumb(image.NewRGBA(image.Rect(0, 0, 960, 2080)), 0)); err != nil {
		t.Fatal(err)
	}
	r.Write("step", map[string]any{"action": "tap", "x": 500, "y": 814}, nil)
	r.Write("step", map[string]any{"action": "type", "text": "a<b"}, nil)
	r.Write("step", map[string]any{"action": "key", "combo": "enter", "error": "busy"}, nil)

	raw, err := os.ReadFile(filepath.Join(root, "20251021-093000", "steps.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(raw)), "\n")
	if len(lines) != 5 || !strings.HasPrefix(lines[0], `{"n": 1, "t": `) || !strings.Contains(lines[0], `"kind": "task"`) ||
		!strings.Contains(lines[1], `"frame": "002.jpg"`) || !strings.Contains(lines[2], `"kind": "step", "action": "tap", "x": 500, "y": 814}`) ||
		!strings.Contains(lines[3], `"text": "a<b"`) {
		t.Fatalf("steps.jsonl:\n%s", raw)
	}
	f, _ := os.Open(filepath.Join(root, "20251021-093000", "002.jpg"))
	cfg, _, err := image.DecodeConfig(f)
	f.Close()
	if err != nil || cfg.Width != 480 || cfg.Height != 1040 {
		t.Fatalf("frame %v %+v", err, cfg)
	}

	run, err := Load(root, "latest")
	if err != nil || len(run.Steps) != 3 || run.Steps[0].Frame != "002.jpg" || !run.Steps[0].Replayable() ||
		run.Steps[2].Replayable() || run.Steps[0].JSON() != `{"action": "tap", "x": 500, "y": 814}` {
		t.Fatalf("run %+v %v", run, err)
	}

	c.t = c.t.Add(time.Minute) // the file's mtime is real time: still within Idle
	r.Write("step", map[string]any{"action": "home"}, nil)
	if ids, _ := IDs(root); len(ids) != 1 {
		t.Fatalf("runs %v", ids)
	}
	c.t = c.t.Add(Idle + time.Hour)
	r.Write("step", map[string]any{"action": "home"}, nil)
	list, _ := List(root, 30)
	if len(list) != 2 || list[0].ID != "20251021-104100" || list[0].Steps != 1 || list[1].Steps != 4 || list[1].Outcome != "ended" ||
		list[1].Screenshots != 1 {
		t.Fatalf("list %+v", list)
	}
	var first map[string]any
	json.Unmarshal([]byte(lines[0]), &first)
	if first["task"] != "" || first["source"] != "cli" {
		t.Fatalf("task record %v", first)
	}
}

func TestNewRunAndPruning(t *testing.T) {
	root := t.TempDir()
	c := &clock{time.Date(2026, 1, 1, 0, 0, 0, 0, time.Local)}
	r := &Recorder{Dir: root, Now: c.now}
	for i := 0; i < MaxRuns+5; i++ {
		if _, err := r.New(""); err != nil {
			t.Fatal(err)
		}
		c.t = c.t.Add(time.Second)
	}
	ids, _ := IDs(root)
	if len(ids) != MaxRuns || ids[len(ids)-1] != "20260101-000005" {
		t.Fatalf("%d runs, oldest %s", len(ids), ids[len(ids)-1])
	}
	c.t = c.t.Add(-time.Second) // same second: a suffix
	if id, _ := r.New("x"); id != "20260101-000144-2" {
		t.Fatalf("id %s", id)
	}
	if _, err := Read(root, "../x"); err == nil {
		t.Fatal("path in run id accepted")
	}
}
