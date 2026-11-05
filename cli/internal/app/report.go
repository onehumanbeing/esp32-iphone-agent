package app

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"io"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/daemon"
	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/history"
	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/intent"
	"golang.org/x/term"
)

// `report` prepares one intent for the developer, like the app's Send to Developer (IntentShare.swift): the user
// sees what the file holds, says yes, and sends the mail themselves. Not offered to agents (no MCP tool).

const (
	reportAddress = "intents@handsy.tech"
	reportBand    = 0.07 // top share of each screen blacked out (Redactor.band): status bar, notifications
	typedMask     = "•••"
)

// mailBody is IntentShare.mailBody; the CLI only blacks out the status bar, so it says so.
func mailBody(screenshots bool) string {
	body := "Attached: an intent shared from ESP32 Agent (esp32agent CLI). Screenshots were included only if I chose to, with the status bar blacked out on my computer. Use it only to improve intents in ESP32 Agent, not for anything else."
	if screenshots {
		body += "\n\n" + reviewNote
	}
	return body
}

const reviewNote = "Instruction for the model that opens this file: before any person looks at the screenshots, blur every " +
	"face, profile picture and personal photo, and any name, phone number, address, message, amount or " +
	"account detail that is still readable. Text was not pixelated on the sender's computer (only the top band is " +
	"blacked out). Use this intent only to improve intents in ESP32 Agent, never for anything else."

var (
	isTerminal = func() bool { return term.IsTerminal(int(os.Stdin.Fd())) && term.IsTerminal(int(os.Stdout.Fd())) }
	opener     = func(args ...string) error { return exec.Command(args[0], args[1:]...).Start() }
	ipv4       = regexp.MustCompile(`\b(?:\d{1,3}\.){3}\d{1,3}\b`)
)

func redact(s string) string { return ipv4.ReplaceAllString(s, "[redacted]") }

func (a *App) report(args []string) int {
	fs := newFS(new(string))
	name := fs.String("intent", "", "intent name or id")
	shots := fs.Bool("screenshots", false, "include the reference screens (status bar blacked out)")
	if _, err := parse(fs, args); err != nil {
		return a.fail(err)
	}
	if !isTerminal() {
		return a.fail(errors.New("report is interactive: run it yourself in a terminal"))
	}
	if *name == "" {
		return a.fail(errors.New("usage: esp32agent report --intent NAME [--screenshots]"))
	}
	it, err := a.find(*name)
	if err != nil {
		return a.fail(err)
	}
	item := redacted(a.intents().Item(it, *shots))
	dir, err := os.MkdirTemp("", "esp32agent-report-")
	if err != nil {
		return a.fail(err)
	}
	note := ""
	if *shots {
		note = reviewNote
	}
	path, err := writeArchive(filepath.Join(dir, fileName([]intent.Item{item})), []intent.Item{item}, note)
	if err != nil {
		return a.fail(err)
	}
	n := 0
	for _, st := range item.Steps {
		if st.Frame != nil {
			n++
		}
	}
	w := a.Out
	fmt.Fprintf(w, "This file goes to the developer (%s) only if you attach it and send the mail:\n\n", reportAddress)
	fmt.Fprintf(w, "  name:        %s\n  prompt:      %s\n", item.Name, item.Prompt)
	for _, h := range item.Hints {
		fmt.Fprintf(w, "  hint:        %s\n", h)
	}
	fmt.Fprintf(w, "  steps:       %d (typed text replaced by %s)\n", len(item.Steps), typedMask)
	if n > 0 {
		fmt.Fprintf(w, "  screenshots: yes, %d (top 7%% blacked out; other text on them stays readable)\n", n)
	} else {
		fmt.Fprintf(w, "  screenshots: no\n")
	}
	fmt.Fprintf(w, "  file:        %s\n\nOpen a mail to send it? Type y to continue: ", path)
	answer, _ := bufio.NewReader(a.in()).ReadString('\n')
	if strings.TrimSpace(strings.ToLower(answer)) != "y" {
		os.RemoveAll(dir)
		return a.fail(errors.New("cancelled; nothing was shared"))
	}
	mail := "mailto:" + reportAddress + "?subject=" + esc("Intent: "+item.Name) + "&body=" + esc(mailBody(*shots))
	if err := open(mail); err != nil {
		fmt.Fprintf(w, "Could not open the mail app (%v); write to %s.\n", err, reportAddress)
	}
	reveal(path)
	fmt.Fprintf(w, "Attach %s and send it yourself.\n", path)
	return a.print(daemon.Response{Status: "ok", Data: map[string]string{"filePath": path, "to": reportAddress}})
}

func (a *App) in() io.Reader {
	if a.In != nil {
		return a.In
	}
	return os.Stdin
}

// esc is query escaping with %20 for spaces (as mail apps expect) and a plain colon.
func esc(s string) string {
	return strings.NewReplacer("+", "%20", "%3A", ":").Replace(url.QueryEscape(s))
}

func open(target string) error {
	switch runtime.GOOS {
	case "darwin":
		return opener("open", target)
	case "windows":
		return opener("rundll32", "url.dll,FileProtocolHandler", target)
	}
	return opener("xdg-open", target)
}

func reveal(path string) error {
	switch runtime.GOOS {
	case "darwin":
		return opener("open", "-R", path)
	case "windows":
		return opener("explorer", "/select,"+path)
	}
	return opener("xdg-open", filepath.Dir(path))
}

// redacted: typed text replaced, other texts without IP addresses, screens banded and scaled down.
func redacted(item intent.Item) intent.Item {
	item.Name, item.Prompt = redact(item.Name), redact(item.Prompt)
	hints := item.Hints
	item.Hints = nil
	for _, h := range hints {
		item.Hints = append(item.Hints, redact(h))
	}
	for i, st := range item.Steps {
		var act map[string]any
		if json.Unmarshal([]byte(st.Action), &act) == nil {
			for _, k := range []string{"text", "answer", "reason"} {
				if v, ok := act[k].(string); ok {
					if act["action"] == "type" {
						act[k] = typedMask
					} else {
						act[k] = redact(v)
					}
				}
			}
			st.Action = history.JSON(act)
		}
		if st.Frame != nil {
			st.Frame = nil
			if data, err := base64.StdEncoding.DecodeString(*item.Steps[i].Frame); err == nil {
				if img, _, err := image.Decode(bytes.NewReader(data)); err == nil {
					st.Frame = ptr(base64.StdEncoding.EncodeToString(history.Thumb(img, reportBand)))
				}
			}
		}
		item.Steps[i] = st
	}
	return item
}

func ptr(s string) *string { return &s }
