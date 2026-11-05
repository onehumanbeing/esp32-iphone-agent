package app

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/daemon"
)

// logs shows the CLI's log (daemon.log), the board's own log (--board), or saves both with the board's state to
// one file (--save) for support@handsy.tech. Nothing is sent anywhere.
func (a *App) logs(args []string) int {
	dev := new(string)
	fs := newFS(dev)
	board := fs.Bool("board", false, "the board's own log (firmware 0.2.3 or later)")
	save := fs.Bool("save", false, "write the CLI log, the board's log and state to one file")
	output := fs.String("output", "", "file for --save (default: esp32agent-logs-<time>.txt here)")
	lines := fs.Int("lines", 50, "last lines of the CLI log to show")
	if _, err := parse(fs, args); err != nil {
		return a.fail(err)
	}
	path := daemon.LogPath(a.Dir)
	switch {
	case *save:
		return a.saveLogs(*dev, *output)
	case *board:
		data, err := a.boardLog(*dev)
		if err != nil {
			return a.fail(err)
		}
		return a.print(daemon.Response{Status: "ok", Data: data})
	}
	return a.print(daemon.Response{Status: "ok", Data: map[string]string{"path": path, "log": tail(path, *lines)}})
}

func (a *App) boardLog(dev string) (map[string]string, error) {
	line, err := a.Client.Call(daemon.Request{Cmd: "boardlog", Device: dev})
	if err != nil {
		return nil, err
	}
	var r struct {
		Status string            `json:"status"`
		Data   map[string]string `json:"data"`
		Error  string            `json:"error"`
	}
	if json.Unmarshal(line, &r) != nil {
		return nil, fmt.Errorf("bad response from the daemon")
	}
	if r.Status != "ok" {
		return nil, fmt.Errorf("%s", r.Error)
	}
	return r.Data, nil
}

func (a *App) saveLogs(dev, output string) int {
	if output == "" {
		output = "esp32agent-logs-" + time.Now().Format("20060102-150405") + ".txt"
	}
	var b strings.Builder
	fmt.Fprintf(&b, "esp32agent %s on %s/%s, %s\n\n", Version, runtime.GOOS, runtime.GOARCH, time.Now().Format(time.RFC3339))
	b.WriteString("== board state ==\n")
	if line, err := a.Client.Call(daemon.Request{Cmd: "info", Device: dev}); err != nil {
		fmt.Fprintf(&b, "unavailable: %v\n", err)
	} else {
		b.Write(line)
	}
	b.WriteString("\n== board log ==\n")
	if data, err := a.boardLog(dev); err != nil {
		fmt.Fprintf(&b, "unavailable: %v\n", err)
	} else {
		fmt.Fprintf(&b, "last reset: %s\n%s%s\n", data["crash"], data["note"], data["log"])
	}
	b.WriteString("\n== CLI log ==\n")
	b.WriteString(tail(strings.TrimSuffix(daemon.LogPath(a.Dir), ".log")+".1.log", 500))
	b.WriteString(tail(daemon.LogPath(a.Dir), 2000))
	if err := os.WriteFile(output, []byte(b.String()), 0o600); err != nil {
		return a.fail(err)
	}
	abs, _ := filepath.Abs(output)
	return a.print(daemon.Response{Status: "ok", Data: map[string]string{
		"filePath": abs, "message": "send this file to support@handsy.tech",
	}})
}

// tail: the last n lines of a file, "" when it doesn't exist.
func tail(path string, n int) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	lines := strings.SplitAfter(string(data), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "")
}
