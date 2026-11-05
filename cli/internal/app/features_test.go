package app

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"image"
	"image/jpeg"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/history"
	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/upgrade"
)

func jpegOf(w, h int) []byte {
	var buf bytes.Buffer
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for i := range img.Pix {
		img.Pix[i] = 255
	}
	jpeg.Encode(&buf, img, nil)
	return buf.Bytes()
}

// withIntent: a config dir with one run (screen, tap, type) saved as intent "Alarm".
func withIntent(t *testing.T) *App {
	a := &App{Err: io.Discard, Dir: t.TempDir()}
	r := &history.Recorder{Dir: history.Root(a.Dir)}
	r.Write("llm", map[string]any{"role": "screenshot"}, jpegOf(960, 2080))
	r.Write("step", map[string]any{"action": "tap", "x": 500, "y": 814}, nil)
	r.Write("step", map[string]any{"action": "type", "text": "secret 192.168.4.1"}, nil)
	if o := run(t, a, "intent", "save", "--name", "Alarm", "--prompt", "Set an alarm on 10.0.0.1", "--hint", "Type the time",
		"--from-run", "latest"); o.Status != "ok" {
		t.Fatalf("save: %+v", o)
	}
	return a
}

func TestReportRefusesWithoutATerminal(t *testing.T) {
	a := withIntent(t)
	isTerminal = func() bool { return false }
	if o := run(t, a, "report", "--intent", "Alarm"); o.Status != "error" || !strings.Contains(o.Error, "interactive") {
		t.Fatalf("%+v", o)
	}
}

func TestReportShowsTheRedactedFileAndOnlyOpensTheMail(t *testing.T) {
	a := withIntent(t)
	isTerminal = func() bool { return true }
	defer func() { isTerminal = func() bool { return false } }()
	var opened [][]string
	opener = func(args ...string) error { opened = append(opened, args); return nil }

	a.In = strings.NewReader("n\n")
	var buf bytes.Buffer
	a.Out = &buf
	if a.Run([]string{"report", "--intent", "alarm"}) == 0 || len(opened) != 0 {
		t.Fatalf("not confirmed, yet: %s %v", buf.String(), opened)
	}

	a.In = strings.NewReader("y\n")
	buf.Reset()
	if code := a.Run([]string{"report", "--intent", "alarm", "--screenshots"}); code != 0 {
		t.Fatalf("report: %s", buf.String())
	}
	text := buf.String()
	for _, want := range []string{"name:        Alarm", "prompt:      Set an alarm on [redacted]", "hint:        Type the time", "steps:       2",
		"screenshots: yes, 2", "Attach "} {
		if !strings.Contains(text, want) {
			t.Errorf("output lacks %q:\n%s", want, text)
		}
	}
	if len(opened) != 2 || !strings.HasPrefix(opened[0][len(opened[0])-1], "mailto:intents@handsy.tech?subject=Intent:%20Alarm&body=Attached:%20") {
		t.Fatalf("opened %v", opened)
	}
	u, _ := url.Parse(opened[0][len(opened[0])-1])
	if !strings.Contains(u.Query().Get("body"), "Instruction for the model") {
		t.Fatalf("body %q", u.Query().Get("body"))
	}
	// the file it wrote; reveal opens it (macOS, Windows) or its folder (Linux), so take the path from the output
	m := regexp.MustCompile(`Attach (\S+) and send it yourself`).FindStringSubmatch(text)
	if m == nil || !strings.HasPrefix(m[1], filepath.Dir(opened[1][len(opened[1])-1])) {
		t.Fatalf("no file path in the output or the reveal call: %s %v", text, opened)
	}
	path := m[1]
	defer os.RemoveAll(filepath.Dir(path))
	data, err := os.ReadFile(path)
	if err != nil || bytes.Contains(data, []byte("secret")) || bytes.Contains(data, []byte("192.168")) || !bytes.Contains(data, []byte("•••")) {
		t.Fatalf("file %v:\n%.600s", err, data)
	}
	var f struct {
		Note    string
		Intents []struct{ Steps []struct{ Frame string } }
	}
	json.Unmarshal(data, &f)
	raw, _ := base64.StdEncoding.DecodeString(f.Intents[0].Steps[0].Frame)
	img, err := jpeg.Decode(bytes.NewReader(raw))
	if err != nil || img.Bounds().Dx() != 480 || f.Note == "" {
		t.Fatalf("screen %v", err)
	}
	if r, _, _, _ := img.At(240, 30).RGBA(); r > 0x2000 {
		t.Fatal("the top band is not black")
	}
	if r, _, _, _ := img.At(240, 500).RGBA(); r < 0xd000 {
		t.Fatal("the rest of the screen was blacked out")
	}
}

func targz(t *testing.T, name, content string) []byte {
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	tw.WriteHeader(&tar.Header{Name: name, Mode: 0o755, Size: int64(len(content)), Typeflag: tar.TypeReg})
	tw.Write([]byte(content))
	tw.Close()
	gz.Close()
	return buf.Bytes()
}

func TestUpgrade(t *testing.T) {
	archive := targz(t, "esp32agent", "#!new binary")
	sum := sha256.Sum256(archive)
	good := hex.EncodeToString(sum[:])
	shaFor := good
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/versions.json" {
			fmt.Fprintf(w, `{"latest":"0.2.0","versions":[{"version":"0.2.0","date":"2026-10-21","assets":{%q:{"url":%q,"sha256":%q}}},
				{"version":"0.1.0","assets":{}}]}`, upgrade.Platform(), "http://"+r.Host+"/esp32agent.tar.gz", shaFor)
			return
		}
		w.Write(archive)
	}))
	defer srv.Close()
	t.Setenv("ESP32AGENT_VERSIONS_URL", srv.URL+"/versions.json")
	exe := filepath.Join(t.TempDir(), "esp32agent")
	os.WriteFile(exe, []byte("old"), 0o755)
	executable = func() (string, error) { return exe, nil }
	old := Version
	defer func() { Version = old }()
	a := &App{Err: io.Discard, Dir: t.TempDir()}

	Version = "0.1.0"
	if o := run(t, a, "upgrade", "--check"); o.Data["current"] != "0.1.0" || o.Data["latest"] != "0.2.0" || o.Data["update_available"] != true {
		t.Fatalf("check: %+v", o)
	}
	shaFor = strings.Repeat("0", 64)
	if o := run(t, a, "upgrade"); o.Status != "error" || !strings.Contains(o.Error, "checksum mismatch") {
		t.Fatalf("bad sha: %+v", o)
	}
	if b, _ := os.ReadFile(exe); string(b) != "old" {
		t.Fatal("replaced despite a bad checksum")
	}
	shaFor = good
	if o := run(t, a, "upgrade"); o.Status != "ok" || o.Data["version"] != "0.2.0" {
		t.Fatalf("upgrade: %+v", o)
	}
	st, _ := os.Stat(exe)
	if b, _ := os.ReadFile(exe); string(b) != "#!new binary" || st.Mode().Perm() != 0o755 {
		t.Fatalf("installed %q %v", b, st.Mode())
	}
	if left, _ := filepath.Glob(filepath.Join(filepath.Dir(exe), ".esp32agent-*")); len(left) != 0 {
		t.Fatalf("temp files left: %v", left)
	}

	Version = "0.2.0"
	if o := run(t, a, "upgrade"); o.Status != "ok" || o.Data["message"] != "already up to date" {
		t.Fatalf("up to date: %+v", o)
	}
	Version = "dev"
	if o := run(t, a, "upgrade", "--check"); o.Data["update_available"] != false || o.Data["note"] == nil {
		t.Fatalf("dev check: %+v", o)
	}
	if o := run(t, a, "upgrade"); o.Status != "error" || !strings.Contains(o.Error, "--force") {
		t.Fatalf("dev upgrade: %+v", o)
	}
	if o := run(t, a, "upgrade", "--force"); o.Status != "ok" {
		t.Fatalf("dev --force: %+v", o)
	}
	if upgrade.Compare("0.10.0", "0.9.1") != 1 || upgrade.Compare("1.0.0-rc1", "1.0.0") != -1 || upgrade.Compare("v1.2.3", "1.2.3") != 0 {
		t.Fatal("semver order")
	}
}

func TestHistoryAndIntentCommands(t *testing.T) {
	a := withIntent(t)
	if o := run(t, a, "history", "list"); o.Status != "ok" || len(o.Data["runs"].([]any)) != 1 {
		t.Fatalf("list: %+v", o)
	}
	if o := run(t, a, "history", "show", "nope"); o.Status != "error" {
		t.Fatalf("show nope: %+v", o)
	}
	if o := run(t, a, "history", "new"); o.Status != "ok" {
		t.Fatalf("new: %+v", o)
	}
	o := run(t, a, "intent", "export", "Alarm", "--output", filepath.Join(a.Dir, "a.esp32intent"))
	if o.Status != "ok" || o.Data["screenshots"] != false {
		t.Fatalf("export: %+v", o)
	}
	if o := run(t, a, "intent", "import", filepath.Join(a.Dir, "a.esp32intent")); o.Status != "ok" || o.Data["skipped"] != 1.0 {
		t.Fatalf("import of a saved one: %+v", o)
	}

	// the MCP tools work without a daemon
	var buf bytes.Buffer
	a.Out = &buf
	a.mcp(strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"intent_show","arguments":{"name":"alarm"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"history","arguments":{"action":"list"}}}
{"jsonrpc":"2.0","id":3,"method":"tools/list"}
`))
	out := buf.String()
	if !strings.Contains(out, `Set an alarm on 10.0.0.1`) || !strings.Contains(out, `20`) || strings.Contains(out, `"isError":true`) ||
		!strings.Contains(out, `"intent_save"`) || strings.Contains(out, "report") || strings.Contains(out, "export") {
		t.Fatalf("mcp:\n%s", out)
	}
}
