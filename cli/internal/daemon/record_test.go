package daemon

import (
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/config"
	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/history"
)

func TestActionsAreRecordedAndKeysPaced(t *testing.T) {
	b := fakeBoard()
	var mu sync.Mutex
	var keyTimes []time.Time
	b.Handle = func(cmd string) string {
		if strings.HasPrefix(cmd, "key ") || strings.HasPrefix(cmd, "type ") {
			mu.Lock()
			keyTimes = append(keyTimes, time.Now())
			mu.Unlock()
		}
		return "ok"
	}
	c, s := start(t, fakeTransport{b})
	call(t, c, Request{Cmd: "pair"})
	b.Status(`{"up":5000,"ap":"idle","w":480,"h":1040}`)
	time.Sleep(50 * time.Millisecond)
	os.WriteFile(config.CalibrationPath(s.Dir, "246f28aa6ad5"), []byte(`{"w":400,"h":860}`), 0o600)

	if r, _ := call(t, c, Request{Cmd: "tap", Pts: []float64{240, 520}}); r.Status != "ok" {
		t.Fatalf("tap: %+v", r)
	}
	call(t, c, Request{Cmd: "keys", Text: "backspace"})
	call(t, c, Request{Cmd: "keys", Text: "backspace"})
	r, data := call(t, c, Request{Cmd: "text", Text: "拿铁"})
	if r.Status != "ok" || data["typed_as"] != "natie" || !strings.Contains(data["note"].(string), "globe key") {
		t.Fatalf("text: %+v", r)
	}
	if _, data := call(t, c, Request{Cmd: "text", Text: "ok"}); data["typed_as"] != nil {
		t.Fatalf("ASCII text with typed_as: %v", data)
	}
	call(t, c, Request{Cmd: "swipe", Pts: []float64{240, 900, 240, 200}})

	mu.Lock()
	for i := 1; i < len(keyTimes); i++ {
		if gap := keyTimes[i].Sub(keyTimes[i-1]); gap < KeyGap {
			t.Errorf("key commands %d and %d only %v apart", i-1, i, gap)
		}
	}
	if len(keyTimes) != 4 {
		t.Errorf("%d key/type commands", len(keyTimes))
	}
	mu.Unlock()

	run, err := history.Load(history.Root(s.Dir), "latest")
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, st := range run.Steps {
		got = append(got, st.JSON())
	}
	want := []string{`{"action": "tap", "x": 500, "y": 500}`, `{"action": "key", "combo": "backspace"}`, `{"action": "key", "combo": "backspace"}`,
		`{"action": "type", "text": "拿铁"}`, `{"action": "type", "text": "ok"}`, `{"action": "swipe", "x1": 500, "x2": 500, "y1": 865, "y2": 192}`}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("recorded:\n%s", strings.Join(got, "\n"))
	}
}
