package app

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"image/png"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/ble"
	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/config"
	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/daemon"
	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/video"
)

type out struct {
	Status string         `json:"status"`
	Data   map[string]any `json:"data"`
	Error  string         `json:"error"`
}

func run(t *testing.T, a *App, args ...string) out {
	t.Helper()
	var buf bytes.Buffer
	a.Out = &buf
	code := a.Run(args)
	var o out
	if err := json.Unmarshal(buf.Bytes(), &o); err != nil {
		t.Fatalf("%v: output %q is not JSON", args, buf.String())
	}
	if (code == 0) != (o.Status == "ok") {
		t.Fatalf("%v: exit %d with %+v", args, code, o)
	}
	return o
}

func TestOutputFormat(t *testing.T) {
	a := &App{Err: io.Discard}
	if o := run(t, a, "version"); o.Status != "ok" || o.Data["version"] != Version {
		t.Fatalf("%+v", o)
	}
	for _, args := range [][]string{{"apps", "list"}, {"dump", "ui"}, {"fs", "ls"}, {"webview", "list"}, {"io", "clipboard", "get"}, {"device", "reboot"}} {
		if o := run(t, a, args...); o.Status != "error" || o.Error != "not supported on ESP32 Agent" {
			t.Fatalf("%v: %+v", args, o)
		}
	}
	if o := run(t, a, "io", "tap", "12"); o.Status != "error" || !strings.Contains(o.Error, "2 comma-separated") {
		t.Fatalf("%+v", o)
	}
}

func TestFlagsAnywhere(t *testing.T) {
	var dev string
	fs := newFS(&dev)
	pos, err := parse(fs, []string{"tap", "-5,10", "--device", "6ad5"})
	if err != nil || dev != "6ad5" || strings.Join(pos, " ") != "tap -5,10" {
		t.Fatalf("%v %q %v", err, dev, pos)
	}
}

func TestMCPHandshake(t *testing.T) {
	a := &App{Err: io.Discard}
	var buf bytes.Buffer
	a.Out = &buf
	in := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"ping"}
{"jsonrpc":"2.0","id":4,"method":"nope"}
`
	a.mcp(strings.NewReader(in))
	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	if len(lines) != 4 {
		t.Fatalf("got %d responses: %s", len(lines), buf.String())
	}
	if !strings.Contains(lines[0], `"protocolVersion":"2025-03-26"`) || !strings.Contains(lines[1], `"type_text"`) ||
		lines[2] != `{"jsonrpc":"2.0","id":3,"result":{}}` || !strings.Contains(lines[3], `-32601`) {
		t.Fatalf("responses:\n%s", buf.String())
	}
}

func TestMCPRequiredIsArray(t *testing.T) {
	a := &App{Err: io.Discard}
	var buf bytes.Buffer
	a.Out = &buf
	a.mcp(strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"tools/list"}` + "\n"))
	var resp struct {
		Result struct {
			Tools []struct {
				Name        string `json:"name"`
				InputSchema struct {
					Required json.RawMessage `json:"required"`
				} `json:"inputSchema"`
			} `json:"tools"`
		} `json:"result"`
	}
	if err := json.Unmarshal(buf.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.Result.Tools) == 0 {
		t.Fatal("no tools")
	}
	for _, tool := range resp.Result.Tools {
		if tool.InputSchema.Required == nil || string(tool.InputSchema.Required) == "null" {
			t.Fatalf("%s: required marshaled as null; want an array", tool.Name)
		}
		var req []string
		if err := json.Unmarshal(tool.InputSchema.Required, &req); err != nil {
			t.Fatalf("%s: required is not an array: %s", tool.Name, tool.InputSchema.Required)
		}
	}
}

// The simulated board (hardware/tests/sim: the firmware's real cli_link.cpp) through the whole CLI and daemon.
func TestSimPairScreenshotTapText(t *testing.T) {
	sim, _ := filepath.Abs("../../../hardware/tests/sim/cli_sim")
	if _, err := os.Stat(sim); err != nil {
		t.Skip("simulated board not built (make -C hardware/tests/sim)")
	}
	if _, err := video.FFmpeg(); err != nil {
		t.Skip(err)
	}
	dir, _ := os.MkdirTemp("/tmp", "e32s")
	t.Cleanup(func() { os.RemoveAll(dir) })
	t.Setenv("ESP32AGENT_HOME", dir)
	t.Setenv("CLI_SIM_NVS", filepath.Join(dir, "nvs"))
	logf, _ := os.Create(filepath.Join(dir, "sim.log"))
	defer logf.Close()
	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	l, err := daemon.Listen(dir)
	if err != nil {
		t.Fatal(err)
	}
	s := &daemon.Server{Transport: &ble.Sim{Bin: sim, Log: logf}, Config: cfg, Dir: dir, Version: "test"}
	go s.Serve(l)
	defer s.Stop()
	a := &App{Err: io.Discard, Dir: dir, Client: &daemon.Client{Dir: dir, NoSpawn: true}}

	if o := run(t, a, "pair"); o.Status != "ok" || o.Data["id"] != "246f28aa6ad5" {
		t.Fatalf("pair: %+v", o)
	}
	o := run(t, a, "screenshot", "--output", dir+"/")
	if o.Status != "ok" {
		t.Fatalf("screenshot: %+v", o)
	}
	f, err := os.Open(o.Data["filePath"].(string))
	if err != nil {
		t.Fatal(err)
	}
	img, err := png.Decode(f)
	f.Close()
	if err != nil || img.Bounds().Dx() != 480 || img.Bounds().Dy() != 1040 {
		t.Fatalf("screenshot image: %v", err)
	}

	// testsrc shows no pointer to calibrate on: use a known span
	os.WriteFile(config.CalibrationPath(dir, "246f28aa6ad5"), []byte(`{"w":400,"h":860}`), 0o600)
	if o := run(t, a, "io", "tap", "240,520"); o.Status != "ok" {
		t.Fatalf("tap: %+v", o)
	}
	if o := run(t, a, "io", "text", "拿铁 ok"); o.Status != "ok" {
		t.Fatalf("text: %+v", o)
	}
	if o := run(t, a, "device", "info"); o.Status != "ok" || o.Data["ap"] != "streaming" {
		t.Fatalf("info: %+v", o)
	}
	if o := run(t, a, "screenshot", "--format", "jpeg", "--max-size", "520", "--output", filepath.Join(dir, "s.jpg")); o.Status != "ok" ||
		o.Data["height"] != 520.0 || o.Data["width"] != 240.0 {
		t.Fatalf("jpeg screenshot: %+v", o)
	}

	// the board's RAM log, read in pages through the daemon, and a file for support with everything
	if o := run(t, a, "logs", "--board"); o.Status != "ok" || !strings.Contains(fmt.Sprint(o.Data["log"]), "boot sim fw 0.2.3\n") ||
		!strings.Contains(fmt.Sprint(o.Data["log"]), "cli: session up") || o.Data["crash"] != "rst power-on, last dump: none" {
		t.Fatalf("logs --board: %+v", o)
	}
	saved := filepath.Join(dir, "support.txt")
	if o := run(t, a, "logs", "--save", "--output", saved); o.Status != "ok" {
		t.Fatalf("logs --save: %+v", o)
	}
	if text, _ := os.ReadFile(saved); !strings.Contains(string(text), "== board log ==") || !strings.Contains(string(text), "wifi: hotspot up") {
		t.Fatalf("saved logs:\n%s", text)
	}

	// the MCP screenshot tool returns the image itself
	var buf bytes.Buffer
	a.Out = &buf
	a.mcp(strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"screenshot","arguments":{}}}` + "\n"))
	var resp struct {
		Result struct {
			Content []struct{ Type, Data, MimeType string }
			IsError bool
		}
	}
	json.Unmarshal(buf.Bytes(), &resp)
	if resp.Result.IsError || len(resp.Result.Content) == 0 || resp.Result.Content[0].MimeType != "image/png" {
		t.Fatalf("mcp screenshot: %.300s", buf.String())
	}
	if raw, err := base64.StdEncoding.DecodeString(resp.Result.Content[0].Data); err != nil || !bytes.HasPrefix(raw, []byte("\x89PNG")) {
		t.Fatal("mcp image is not a PNG")
	}

	time.Sleep(100 * time.Millisecond)
	logged, _ := os.ReadFile(filepath.Join(dir, "sim.log"))
	for _, want := range []string{" stream on\n", " home\n", " move 200 430\n", " click\n", " type natie\n", " key space\n", " type ok\n"} {
		if !strings.Contains(string(logged), want) {
			t.Errorf("the board never got %q:\n%s", strings.TrimSpace(want), logged)
		}
	}
}
