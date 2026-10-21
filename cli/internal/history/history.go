// Package history records what the CLI did on the phone, in the iOS app's trace format (TraceStore.swift):
// runs/<yyyyMMdd-HHmmss>/steps.jsonl, one JSON object per line {n, t, kind, frame?, ...}, frames %03d.jpg.
// Actions use the app's 0-1000 screen units, so a run can become a saved intent.
package history

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	Idle    = 10 * time.Minute // a new run starts after this long without a record
	MaxRuns = 100
	Layout  = "20060102-150405"
	Steps   = "steps.jsonl"
)

// Root is the runs folder in the config dir.
func Root(configDir string) string { return filepath.Join(configDir, "runs") }

// Recorder appends to the current run; it keeps no state but the files, so `history new` from another process
// just makes a newer run folder.
type Recorder struct {
	Dir string // the runs folder
	Now func() time.Time
	mu  sync.Mutex
}

func (r *Recorder) now() time.Time {
	if r.Now != nil {
		return r.Now()
	}
	return time.Now()
}

// New starts a run (task may be empty) and drops the oldest beyond MaxRuns.
func (r *Recorder) New(task string) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.start(task)
}

func (r *Recorder) start(task string) (string, error) {
	if err := os.MkdirAll(r.Dir, 0o700); err != nil {
		return "", err
	}
	base := r.now().Format(Layout)
	id := base
	for i := 2; ; i++ {
		if err := os.Mkdir(filepath.Join(r.Dir, id), 0o700); err == nil {
			break
		} else if !errors.Is(err, os.ErrExist) {
			return "", err
		}
		id = fmt.Sprintf("%s-%d", base, i)
	}
	if err := r.append(id, 1, "task", map[string]any{"task": task, "source": "cli"}, nil); err != nil {
		return "", err
	}
	runs, _ := IDs(r.Dir)
	for len(runs) > MaxRuns {
		os.RemoveAll(filepath.Join(r.Dir, runs[len(runs)-1]))
		runs = runs[:len(runs)-1]
	}
	return id, nil
}

// Write appends one record to the current run (a new one after Idle); frame is a JPEG or nil.
func (r *Recorder) Write(kind string, rec map[string]any, frame []byte) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	id, n := r.current()
	if id == "" {
		var err error
		if id, err = r.start(""); err != nil {
			return err
		}
		n = 1
	}
	return r.append(id, n+1, kind, rec, frame)
}

// current is the newest run if its last record is within Idle, and its record count.
func (r *Recorder) current() (string, int) {
	runs, _ := IDs(r.Dir)
	if len(runs) == 0 {
		return "", 0
	}
	raw, err := os.ReadFile(filepath.Join(r.Dir, runs[0], Steps))
	if err != nil {
		return "", 0
	}
	lines := bytes.Split(bytes.TrimSpace(raw), []byte("\n"))
	var last struct{ T float64 }
	if json.Unmarshal(lines[len(lines)-1], &last) != nil || r.now().Sub(unix(last.T)) > Idle {
		return "", 0
	}
	return runs[0], bytes.Count(raw, []byte("\n"))
}

func unix(t float64) time.Time { return time.UnixMilli(int64(t * 1000)) }

func (r *Recorder) append(id string, n int, kind string, rec map[string]any, frame []byte) error {
	dir := filepath.Join(r.Dir, id)
	line := map[string]any{}
	for k, v := range rec {
		line[k] = v
	}
	line["n"], line["kind"] = n, kind
	line["t"] = float64(r.now().UnixMilli()) / 1000
	if frame != nil {
		name := fmt.Sprintf("%03d.jpg", n)
		if err := os.WriteFile(filepath.Join(dir, name), frame, 0o600); err != nil {
			return err
		}
		line["frame"] = name
	}
	b, err := marshal(line)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(filepath.Join(dir, Steps), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.Write(append(b, '\n'))
	return err
}

// marshal writes like the app's PyJSON.dumps: n, t, kind first, then the rest sorted, ", " and ": ", no escaping.
func marshal(m map[string]any) ([]byte, error) {
	var keys []string
	for k := range m {
		if k != "n" && k != "t" && k != "kind" {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	var buf bytes.Buffer
	buf.WriteByte('{')
	var head []string
	for _, k := range []string{"n", "t", "kind"} {
		if _, ok := m[k]; ok {
			head = append(head, k)
		}
	}
	for i, k := range append(head, keys...) {
		if i > 0 {
			buf.WriteString(", ")
		}
		kb, _ := json.Marshal(k)
		buf.Write(kb)
		buf.WriteString(": ")
		var vb bytes.Buffer
		enc := json.NewEncoder(&vb)
		enc.SetEscapeHTML(false)
		if err := enc.Encode(m[k]); err != nil {
			return nil, err
		}
		buf.Write(bytes.TrimRight(vb.Bytes(), "\n"))
	}
	buf.WriteByte('}')
	return buf.Bytes(), nil
}

// IDs lists the run folders, newest first.
func IDs(root string) ([]string, error) {
	items, err := os.ReadDir(root)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	var ids []string
	for _, it := range items {
		if it.IsDir() && !strings.HasPrefix(it.Name(), ".") {
			ids = append(ids, it.Name())
		}
	}
	sort.Sort(sort.Reverse(sort.StringSlice(ids)))
	return ids, nil
}

// Record is one line of steps.jsonl.
type Record map[string]any

func (r Record) Str(k string) string { s, _ := r[k].(string); return s }

// Read parses a run's steps.jsonl; bad lines are skipped.
func Read(root, id string) ([]Record, error) {
	if id == "" || id != filepath.Base(id) || strings.HasPrefix(id, ".") {
		return nil, fmt.Errorf("bad run id %q", id)
	}
	f, err := os.Open(filepath.Join(root, id, Steps))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("no run %s (see esp32agent history list)", id)
		}
		return nil, err
	}
	defer f.Close()
	var out []Record
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<16), 1<<24)
	for sc.Scan() {
		var r Record
		if json.Unmarshal(sc.Bytes(), &r) == nil {
			out = append(out, r)
		}
	}
	return out, sc.Err()
}
