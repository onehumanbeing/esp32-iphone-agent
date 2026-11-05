package intent

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/jpeg"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/history"
)

func tinyJPEG(t *testing.T) []byte {
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, image.NewRGBA(image.Rect(0, 0, 4, 8)), nil); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// sample is a file as the app writes it (JSONEncoder: pretty, sorted keys, " : ").
func sample(t *testing.T) []byte {
	return []byte(`{
  "format" : 1,
  "intents" : [
    {
      "hints" : [
        "Type the time instead of scrolling the wheel"
      ],
      "icon" : "alarm",
      "name" : "Alarm 7:00",
      "prompt" : "Set an alarm for 7:00 AM every day",
      "steps" : [
        {
          "action" : "{\"action\": \"tap\", \"x\": 500, \"y\": 814}",
          "frame" : "` + base64.StdEncoding.EncodeToString(tinyJPEG(t)) + `",
          "sure" : true
        },
        {
          "action" : "not json",
          "sure" : true
        },
        {
          "action" : "{\"action\": \"type\", \"text\": \"0700\"}",
          "frame" : "bm90IGFuIGltYWdl",
          "sure" : false
        }
      ]
    },
    {
      "name" : "",
      "prompt" : "  "
    }
  ]
}`)
}

var uuidRe = regexp.MustCompile(`^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$`)

func TestImportExportRoundTripAndDedupe(t *testing.T) {
	items, err := Decode(sample(t))
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 || len(items[0].Steps) != 2 || items[0].Steps[0].Frame == nil || items[0].Steps[1].Frame != nil {
		t.Fatalf("decoded %+v", items)
	}
	s := Store{Dir: t.TempDir()}
	added, skipped, err := s.Import(items)
	if err != nil || len(added) != 1 || skipped != 0 {
		t.Fatalf("import %v %d %v", added, skipped, err)
	}
	it := added[0]
	if !uuidRe.MatchString(it.ID) || *it.Steps[0].Frame != "s01.jpg" || it.Steps[1].Frame != nil || it.Steps[1].Sure {
		t.Fatalf("imported %+v", it)
	}
	if data, _ := os.ReadFile(filepath.Join(s.Dir, "intent-frames", it.ID, "s01.jpg")); !bytes.Equal(data, tinyJPEG(t)) {
		t.Fatal("frame not saved")
	}
	// the same file again (names differ in case only): nothing new
	again, _ := Decode(bytes.ReplaceAll(sample(t), []byte("Alarm 7:00"), []byte("ALARM 7:00")))
	if added, skipped, _ := s.Import(again); len(added) != 0 || skipped != 1 {
		t.Fatalf("dedupe: %d added, %d skipped", len(added), skipped)
	}

	// export: no screens by default, with --screenshots the same bytes; never ids or history
	saved, _ := s.Load()
	saved[0].History = []RunStat{{Run: "x", OK: true}}
	plain, _ := Encode([]Item{s.Item(saved[0], false)}, "")
	full, _ := Encode([]Item{s.Item(saved[0], true)}, "")
	if bytes.Contains(plain, []byte(`"frame"`)) || bytes.Contains(full, []byte(it.ID)) || bytes.Contains(full, []byte("history")) ||
		!bytes.Contains(full, []byte(base64.StdEncoding.EncodeToString(tinyJPEG(t)))) {
		t.Fatalf("export:\n%s", full)
	}
	var f map[string]any
	if json.Unmarshal(full, &f) != nil || f["format"] != 1.0 || !strings.HasPrefix(string(full), "{\n  \"format\": 1,\n  \"intents\": [") {
		t.Fatalf("export format:\n%s", full)
	}
	// into a fresh store: identical
	back, err := Decode(full)
	if err != nil {
		t.Fatal(err)
	}
	s2 := Store{Dir: t.TempDir()}
	added, _, _ = s2.Import(back)
	if a, b := s2.Item(added[0], true), s.Item(saved[0], true); !equal(a, b) || added[0].ID == it.ID {
		t.Fatalf("round trip:\n%+v\n%+v", a, b)
	}

	if _, err := Decode([]byte(`{"format":2,"intents":[]}`)); err == nil || !strings.Contains(err.Error(), "newer") {
		t.Fatalf("format 2: %v", err)
	}
	if _, err := Decode([]byte(`{"name":"x"}`)); err == nil {
		t.Fatal("not an intent file accepted")
	}
}

func equal(a, b Item) bool {
	x, _ := json.Marshal(a)
	y, _ := json.Marshal(b)
	return bytes.Equal(x, y)
}

func TestSaveFromRun(t *testing.T) {
	dir := t.TempDir()
	r := &history.Recorder{Dir: history.Root(dir)}
	r.Write("llm", map[string]any{"role": "screenshot"}, tinyJPEG(t))
	r.Write("step", map[string]any{"action": "tap", "x": 500, "y": 814}, nil)
	r.Write("step", map[string]any{"action": "longpress", "x": 1, "y": 2, "ms": 1000}, nil)
	r.Write("step", map[string]any{"action": "key", "combo": "enter", "error": "busy"}, nil)
	r.Write("step", map[string]any{"action": "type", "text": "07:00"}, nil)
	ids, _ := history.IDs(history.Root(dir))
	s := Store{Dir: dir}

	it, err := s.Save(SaveOpts{Name: "Alarm", Prompt: "Set an alarm", Hints: []string{"a", " "}, FromRun: ids[0]})
	if err != nil {
		t.Fatal(err)
	}
	if len(it.Steps) != 2 || it.Steps[0].Action != `{"action": "tap", "x": 500, "y": 814}` || !it.Steps[0].Sure || *it.Steps[0].Frame != "s01.jpg" ||
		len(it.Hints) != 1 || it.RefRun != ids[0] {
		t.Fatalf("saved %+v", it)
	}
	if _, err := s.Save(SaveOpts{Name: "x", Prompt: "y", FromRun: ids[0], Steps: []int{2}}); err == nil {
		t.Fatal("a long press was saved as a replayable step")
	}
	again, err := s.Save(SaveOpts{Name: "alarm", Prompt: "Set it", FromRun: ids[0], Steps: []int{4}})
	items, _ := s.Load()
	if err != nil || again.ID != it.ID || len(items) != 1 || len(again.Steps) != 1 || !strings.Contains(again.Steps[0].Action, "07:00") {
		t.Fatalf("replace %+v %v", again, err)
	}
	if _, err := s.Save(SaveOpts{Name: "h", Prompt: "p", Hints: strings.Split("1 2 3 4 5 6 7", " ")}); err == nil {
		t.Fatal("7 hints accepted")
	}
	if _, err := s.Delete("ALARM"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(s.Frames(it.ID)); !os.IsNotExist(err) {
		t.Fatal("frames left after delete")
	}
}
