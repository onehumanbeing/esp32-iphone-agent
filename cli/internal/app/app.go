// Package app is the esp32agent command line: mobilecli-style commands, each a request to the daemon.
package app

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/ble"
	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/config"
	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/daemon"
)

// Version is set at build time (-ldflags "-X .../internal/app.Version=1.2.3").
var Version = "dev"

const usage = `esp32agent: see and drive an iPhone through an ESP32 Agent board, over Bluetooth.

  devices                          boards nearby
  pair | unpair                    pair this computer (within 3 min of plugging the board in)
  screenshot [--format png|jpeg] [--quality N] [--scale F] [--max-size N] [--output PATH|-]
  io tap X,Y [--aim] [--count N]   coordinates are screenshot pixels; --count 2 double-taps
  io longpress X,Y [--duration MS]
  io swipe X1,Y1,X2,Y2
  io text 'TEXT'                   ASCII; Chinese is typed as pinyin
  io keys COMBO                    enter, esc, tab, backspace, space, up, cmd+a, ...
  io button HOME
  screencapture --format h264|mjpeg   video to stdout
  device info                      board status
  net                              the CLI's link (BLE or Wi-Fi) and the board's Wi-Fi
  net via auto|ble                 auto: move to Wi-Fi when this computer reaches the board (default)
  net join SSID [PASSWORD]         the board joins your Wi-Fi (the iPhone must mirror over it too)
  net hotspot                      the board opens its own hotspot again
  calibrate                        measure the pointer (automatic on the first tap)
  history list | show RUN | new    what was done on the phone (runs; a new one after 10 min idle)
  intent list | show NAME          saved intents (the app's format)
  intent save --name N --prompt P [--hint H ...] [--from-run RUN [--steps 1,3,4]]
  intent delete NAME
  intent export NAME... [--screenshots] [--output FILE]   .esp32intent file for the iOS app
  intent import FILE
  report --intent NAME [--screenshots]   prepare a mail to the developer with one intent; you send it
  upgrade [--check] [--force]      install the latest release
  mcp                              MCP server on stdio
  skill install                    agent skill for Claude Code / Codex
  logs [--board] [--save]          the CLI's log; --board the board's; --save one file for support
  daemon [stop]                    the background process (started automatically)
  version

  --device ID or ESP32AGENT_DEVICE when several boards are around.
`

var errUnsupported = errors.New("not supported on ESP32 Agent")

// App runs commands; Out gets the JSON (or raw bytes), Client reaches the daemon.
type App struct {
	In     io.Reader // report's confirmation; os.Stdin when nil
	Out    io.Writer
	Err    io.Writer
	Client *daemon.Client
	Dir    string
}

func Main(args []string) int {
	dir, err := config.Dir()
	a := &App{Out: os.Stdout, Err: os.Stderr, Dir: dir}
	if err != nil {
		return a.print(daemon.Response{Status: "error", Error: err.Error()})
	}
	a.Client = &daemon.Client{Dir: dir, Version: Version}
	return a.Run(args)
}

func (a *App) print(r daemon.Response) int {
	json.NewEncoder(a.Out).Encode(r)
	if r.Status != "ok" {
		return 1
	}
	return 0
}

func (a *App) fail(err error) int {
	return a.print(daemon.Response{Status: "error", Error: err.Error()})
}

// call sends a request and prints the daemon's response as is.
func (a *App) call(req daemon.Request) int {
	line, err := a.Client.Call(req)
	if err != nil {
		return a.fail(err)
	}
	var r daemon.Response
	if json.Unmarshal(line, &r) != nil {
		return a.fail(errors.New("bad response from the daemon"))
	}
	a.Out.Write(line)
	if r.Status != "ok" {
		return 1
	}
	return 0
}

func (a *App) Run(args []string) int {
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" || args[0] == "help" {
		fmt.Fprint(a.Err, usage)
		return 0
	}
	if args[0] == "--version" {
		args[0] = "version"
	}
	cmd, rest := args[0], args[1:]
	dev := new(string)
	fs := newFS(dev)
	switch cmd {
	case "version":
		return a.print(daemon.Response{Status: "ok", Data: map[string]string{"version": Version}})
	case "daemon":
		idle := fs.Duration("idle-timeout", 10*time.Minute, "exit after this long without requests (0: never)")
		pos, err := parse(fs, rest)
		if err != nil {
			return a.fail(err)
		}
		if len(pos) > 0 && pos[0] == "stop" {
			return a.call(daemon.Request{Cmd: "stop"})
		}
		return a.daemon(*idle)
	case "mcp":
		return a.mcp(os.Stdin)
	case "history":
		return a.history(rest)
	case "intent", "intents":
		return a.intent(rest)
	case "report":
		return a.report(rest)
	case "logs":
		return a.logs(rest)
	case "upgrade":
		return a.upgrade(rest)
	case "skill":
		if len(rest) == 0 || rest[0] != "install" {
			return a.fail(errors.New("usage: esp32agent skill install"))
		}
		return a.skillInstall()
	case "devices", "pair", "unpair", "calibrate":
		if _, err := parse(fs, rest); err != nil {
			return a.fail(err)
		}
		return a.call(daemon.Request{Cmd: cmd, Device: *dev})
	case "device":
		pos, err := parse(fs, rest)
		if err != nil {
			return a.fail(err)
		}
		if len(pos) >= 2 && pos[0] == "send" { // undocumented: one raw board command, for debugging
			return a.call(daemon.Request{Cmd: "send", Device: *dev, Text: strings.Join(pos[1:], " ")})
		}
		if len(pos) == 0 || pos[0] != "info" {
			return a.fail(errUnsupported)
		}
		return a.call(daemon.Request{Cmd: "info", Device: *dev})
	case "net":
		pos, err := parse(fs, rest)
		if err != nil {
			return a.fail(err)
		}
		text := strings.Join(pos, " ")
		if len(pos) >= 2 && pos[0] == "join" { // SSIDs and passwords may hold spaces
			text = "join " + pos[1] + "\x00" + strings.Join(pos[2:], " ")
		}
		return a.call(daemon.Request{Cmd: "net", Device: *dev, Text: text})
	case "screenshot":
		return a.screenshot(fs, dev, rest)
	case "screencapture":
		format := fs.String("format", "mjpeg", "h264 or mjpeg")
		quality := fs.Int("quality", 80, "JPEG quality (mjpeg)")
		if _, err := parse(fs, rest); err != nil {
			return a.fail(err)
		}
		line, err := a.Client.Stream(daemon.Request{Cmd: "screencapture", Device: *dev, Format: *format, Quality: *quality}, a.Out)
		if err != nil {
			return a.fail(err)
		}
		var r daemon.Response
		if json.Unmarshal(line, &r) == nil && r.Status != "ok" {
			return a.print(r)
		}
		return 0
	case "io":
		return a.io(fs, dev, rest)
	}
	return a.fail(errUnsupported)
}

func newFS(dev *string) *flag.FlagSet {
	fs := flag.NewFlagSet("esp32agent", flag.ContinueOnError)
	fs.StringVar(dev, "device", os.Getenv("ESP32AGENT_DEVICE"), "board id")
	return fs
}

func (a *App) io(fs *flag.FlagSet, dev *string, args []string) int {
	aim := fs.Bool("aim", false, "find the pointer on screen and correct a miss before tapping")
	ms := fs.Int("duration", 1000, "long press, ms")
	count := fs.Int("count", 1, "taps in a row at the point (2: double tap)")
	pos, err := parse(fs, args)
	if err != nil {
		return a.fail(err)
	}
	if len(pos) == 0 {
		return a.fail(errors.New("usage: esp32agent io tap|longpress|swipe|text|keys|button ..."))
	}
	sub, arg := pos[0], strings.Join(pos[1:], " ")
	req := daemon.Request{Cmd: sub, Device: *dev, Aim: *aim, Ms: *ms, Count: *count, Text: arg}
	switch sub {
	case "tap", "longpress", "swipe":
		n := 2
		if sub == "swipe" {
			n = 4
		}
		if req.Pts, err = coords(arg, n); err != nil {
			return a.fail(err)
		}
	case "text", "keys", "button":
		if len(pos) < 2 {
			return a.fail(fmt.Errorf("usage: esp32agent io %s VALUE", sub))
		}
	default:
		return a.fail(errUnsupported)
	}
	return a.call(req)
}

func (a *App) screenshot(fs *flag.FlagSet, dev *string, args []string) int {
	format := fs.String("format", "png", "png or jpeg")
	quality := fs.Int("quality", 90, "JPEG quality 1-100")
	scale := fs.Float64("scale", 1, "0-1")
	maxSize := fs.Int("max-size", 0, "max(width, height) in pixels")
	output := fs.String("output", "", "file, directory/, or - for stdout")
	if _, err := parse(fs, args); err != nil {
		return a.fail(err)
	}
	if *format == "jpg" {
		*format = "jpeg"
	}
	line, err := a.Client.Call(daemon.Request{Cmd: "screenshot", Device: *dev, Format: *format, Quality: *quality,
		Scale: *scale, MaxSize: *maxSize})
	if err != nil {
		return a.fail(err)
	}
	var r struct {
		daemon.Response
		Data struct {
			Format, Data, Device string
			Width, Height        int
		} `json:"data"`
	}
	if err := json.Unmarshal(line, &r); err != nil {
		return a.fail(err)
	}
	if r.Status != "ok" {
		return a.print(r.Response)
	}
	img, err := base64.StdEncoding.DecodeString(r.Data.Data)
	if err != nil {
		return a.fail(err)
	}
	if *output == "-" {
		a.Out.Write(img)
		return 0
	}
	path, err := screenshotPath(*output, r.Data.Device, r.Data.Format)
	if err != nil {
		return a.fail(err)
	}
	if err := os.WriteFile(path, img, 0o644); err != nil {
		return a.fail(err)
	}
	return a.print(daemon.Response{Status: "ok", Data: map[string]any{"format": r.Data.Format, "filePath": path,
		"width": r.Data.Width, "height": r.Data.Height}})
}

// screenshotPath: a file path as given, or screenshot-<device>-<time>.<ext> in a directory (default: cwd).
func screenshotPath(out, device, format string) (string, error) {
	if out != "" && !os.IsPathSeparator(out[len(out)-1]) {
		return filepath.Abs(out)
	}
	ext := "png"
	if format == "jpeg" {
		ext = "jpg"
	}
	base, err := filepath.Abs(filepath.Join(out, fmt.Sprintf("screenshot-%s-%s", device, time.Now().Format("20060102150405"))))
	if err != nil {
		return "", err
	}
	path := base + "." + ext
	for i := 1; ; i++ {
		if _, err := os.Stat(path); err != nil {
			return path, nil
		}
		path = fmt.Sprintf("%s-%d.%s", base, i, ext)
	}
}

func (a *App) daemon(idle time.Duration) int {
	cfg, err := config.Load()
	if err != nil {
		return a.fail(err)
	}
	l, err := daemon.Listen(a.Dir)
	if err != nil {
		return a.fail(err)
	}
	log.SetFlags(log.LstdFlags)
	log.Printf("esp32agent %s daemon on %s", Version, daemon.SocketPath(a.Dir))
	s := &daemon.Server{Transport: ble.Default(), Config: cfg, Dir: a.Dir, Version: Version, Idle: idle}
	if err := s.Serve(l); err != nil {
		log.Print(err)
		return 1
	}
	os.Remove(daemon.SocketPath(a.Dir))
	return 0
}
