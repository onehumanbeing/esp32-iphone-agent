package app

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"golang.org/x/term"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/daemon"
)

// netJoin is `net join` without arguments: over the BLE session, ask for the Wi-Fi's name and password (not
// echoed, not in the shell history), send them to the board, and wait until the CLI's link moves to that Wi-Fi.
func (a *App) netJoin(dev string) int {
	in := a.In
	if in == nil {
		in = os.Stdin
	}
	r := bufio.NewReader(in)
	if _, err := a.Client.Call(daemon.Request{Cmd: "net", Device: dev}); err != nil { // connected over BLE first
		return a.fail(err)
	}
	fmt.Fprint(a.Err, "Wi-Fi name (SSID): ")
	ssid, _ := r.ReadString('\n')
	ssid = strings.TrimRight(ssid, "\r\n")
	if ssid == "" {
		return a.fail(errors.New("no Wi-Fi name given"))
	}
	fmt.Fprint(a.Err, "Password (empty for an open network): ")
	var pass string
	if f, ok := in.(*os.File); ok && term.IsTerminal(int(f.Fd())) {
		b, err := term.ReadPassword(int(f.Fd()))
		fmt.Fprintln(a.Err)
		if err != nil {
			return a.fail(err)
		}
		pass = string(b)
	} else {
		pass, _ = r.ReadString('\n')
		pass = strings.TrimRight(pass, "\r\n")
	}
	if _, err := a.Client.Call(daemon.Request{Cmd: "net", Device: dev, Text: "join " + ssid + "\x00" + pass}); err != nil {
		return a.fail(err)
	}
	fmt.Fprintf(a.Err, "Sent over Bluetooth. The board is joining %q; put the iPhone on the same Wi-Fi to mirror.\n", ssid)
	var last []byte
	for deadline := time.Now().Add(45 * time.Second); time.Now().Before(deadline); time.Sleep(2 * time.Second) {
		line, err := a.Client.Call(daemon.Request{Cmd: "net", Device: dev})
		if err != nil {
			continue
		}
		last = line
		var resp struct {
			Data struct {
				Via   string `json:"via"`
				Board struct {
					Mode string `json:"mode"`
					IP   string `json:"ip"`
				} `json:"board"`
			} `json:"data"`
		}
		json.Unmarshal(line, &resp)
		if d := resp.Data; d.Via == "wifi" {
			fmt.Fprintf(a.Err, "Done: commands and video now go over Wi-Fi (%s).\n", d.Board.IP)
			a.waitMirroring(dev)
			a.Out.Write(line)
			return 0
		} else if d.Board.Mode == "sta" && d.Board.IP != "" && d.Board.IP != "0.0.0.0" {
			fmt.Fprintf(a.Err, "board is on Wi-Fi at %s; moving the link...\n", d.Board.IP)
		}
	}
	if last != nil {
		a.Out.Write(last)
	}
	return a.fail(errors.New("the link did not move to Wi-Fi in 45 s: is this computer on the same Wi-Fi, and the password right? (esp32agent net shows the board's state; commands still work over BLE)"))
}

// waitMirroring walks the user through the step after the network: the iPhone mirroring to the board.
func (a *App) waitMirroring(dev string) {
	state := func() (ap, name string) {
		line, err := a.Client.Call(daemon.Request{Cmd: "info", Device: dev})
		if err != nil {
			return "", ""
		}
		var r struct {
			Data struct {
				AP   string `json:"ap"`
				Name string `json:"name"`
			} `json:"data"`
		}
		json.Unmarshal(line, &r)
		return r.Data.AP, r.Data.Name
	}
	ap, name := state()
	if ap == "streaming" {
		fmt.Fprintln(a.Err, "Screen Mirroring is on. Ready.")
		return
	}
	if name == "" {
		name = "ESP32 Agent"
	}
	fmt.Fprintf(a.Err, "Next, on the iPhone (on the same Wi-Fi): Control Center → Screen Mirroring → %q.\nWaiting for it (Ctrl+C to skip)...\n", name)
	for deadline := time.Now().Add(2 * time.Minute); time.Now().Before(deadline); time.Sleep(2 * time.Second) {
		if ap, _ = state(); ap == "streaming" {
			fmt.Fprintln(a.Err, "Screen Mirroring is on. Ready: try esp32agent screenshot.")
			return
		}
	}
	fmt.Fprintln(a.Err, "No mirroring yet. Is the iPhone on the same Wi-Fi as the board? Start it later the same way.")
}
