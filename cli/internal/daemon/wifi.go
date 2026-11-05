package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/proto"
)

// wifiLink moves a board's session to its Wi-Fi link when this computer can reach the board's IP (same Wi-Fi,
// or joined to the board's hotspot), and back to BLE when that link drops. BLE stays connected the whole time:
// it finds the board, carries the IP (status), and is the way back. docs/cli-protocol.md, "Wi-Fi link".
type wifiLink struct {
	dial  func(ctx context.Context, ip string) (proto.Link, error)
	hello func(ctx context.Context, l proto.Link) (*proto.Session, error)
	every time.Duration // how often run checks

	mu      sync.Mutex
	mode    string    // "auto": Wi-Fi when reachable; "ble": stay on BLE
	retryAt time.Time // after a failed try, or a fall back
	backoff time.Duration
	lastErr string
	done    chan struct{}
	once    sync.Once
	moving  bool
}

const (
	wifiCheck      = 2 * time.Second
	wifiBackoffMin = 10 * time.Second
	wifiBackoffMax = time.Minute
)

// TransportMode is ESP32AGENT_TRANSPORT: "ble" keeps sessions on BLE; anything else is "auto".
func TransportMode() string {
	if os.Getenv("ESP32AGENT_TRANSPORT") == "ble" {
		return "ble"
	}
	return "auto"
}

func newWifiLink(dial func(context.Context, string) (proto.Link, error),
	hello func(context.Context, proto.Link) (*proto.Session, error)) *wifiLink {
	return &wifiLink{dial: dial, hello: hello, every: wifiCheck, mode: TransportMode(), done: make(chan struct{})}
}

func (w *wifiLink) stop() { w.once.Do(func() { close(w.done) }) }

func (w *wifiLink) setMode(m string) {
	w.mu.Lock()
	w.mode, w.retryAt, w.backoff, w.lastErr = m, time.Time{}, 0, ""
	w.mu.Unlock()
}

func (w *wifiLink) state() (mode, lastErr string) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.mode, w.lastErr
}

// claim marks a move in progress; false if one already is.
func (w *wifiLink) claim() bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.moving {
		return false
	}
	w.moving = true
	return true
}

func (w *wifiLink) release() {
	w.mu.Lock()
	w.moving = false
	w.mu.Unlock()
}

func (w *wifiLink) failed(err string) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.backoff = min(max(w.backoff*2, wifiBackoffMin), wifiBackoffMax)
	w.retryAt = time.Now().Add(w.backoff)
	w.lastErr = err
}

// run checks every wifiCheck whether the session should move, until stop.
func (w *wifiLink) run(c *Conn) {
	t := time.NewTicker(w.every)
	defer t.Stop()
	for {
		select {
		case <-w.done:
			return
		case <-t.C:
		}
		w.mu.Lock()
		mode, due := w.mode, time.Now().After(w.retryAt)
		w.mu.Unlock()
		switch via := c.Via(); {
		case via == "wifi" && mode == "ble":
			c.mu.Lock()
			bl := c.bleLink
			c.mu.Unlock()
			if bl != nil {
				w.fallBack(c, bl)
			}
		case via == "ble" && mode == "auto" && due:
			if ip := boardIP(c); ip != "" {
				w.up(c, ip)
			}
		}
	}
}

// boardIP is the board's address from its status, "" while it has none (station mode, not connected).
func boardIP(c *Conn) string {
	st, _ := c.Status()
	ip, _ := st["ip"].(string)
	if n, _ := st["net"].(string); n != "ap" && n != "sta" {
		return ""
	}
	if a := net.ParseIP(ip); a == nil || a.IsUnspecified() {
		return ""
	}
	return ip
}

// up opens the Wi-Fi link and moves the session to it.
func (w *wifiLink) up(c *Conn, ip string) {
	if !w.claim() {
		return
	}
	defer w.release()
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	dctx, dcancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	l, err := w.dial(dctx, ip)
	dcancel()
	if err != nil {
		w.failed("board's Wi-Fi not reachable from this computer (" + ip + ")")
		return
	}
	sess, err := w.hello(ctx, l)
	if err != nil || idHex(sess.BoardID) != c.ID {
		l.Close()
		w.failed("Wi-Fi link refused: " + errText(err))
		return
	}
	if c.Via() != "ble" { // the BLE session ended meanwhile: the next request reconnects
		sess.Close()
		return
	}
	c.attach(sess, "wifi", l)
	if err := c.start(); err != nil {
		w.failed("Wi-Fi link: " + err.Error())
		c.detach(sess, err) // falls back to BLE
		return
	}
	w.mu.Lock()
	w.backoff, w.lastErr = 0, ""
	w.mu.Unlock()
	log.Printf("%s: session moved to Wi-Fi (%s)", c.ID, ip)
}

// fallBack opens a new session on the BLE link bl, kept while the session ran over Wi-Fi.
func (w *wifiLink) fallBack(c *Conn, bl proto.Link) {
	w.failed("Wi-Fi link dropped")
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	sess, err := w.hello(ctx, bl)
	if err == nil {
		if err = c.attach(sess, "ble", bl); err == nil {
			err = c.start()
		}
		if err == nil {
			log.Printf("%s: session back on BLE", c.ID)
			return
		}
		c.detach(sess, err)
	}
	log.Printf("%s: no way back over BLE (%v); the next request reconnects", c.ID, err)
	c.mu.Lock()
	if c.bleLink == bl {
		c.bleLink = nil
	}
	c.mu.Unlock()
	bl.Close()
}

func errText(err error) string {
	if err == nil {
		return "another board"
	}
	return err.Error()
}

// net: the CLI's link and the board's Wi-Fi. arg: "" (show), "via auto|ble", "join SSID PASS", "hotspot".
func (s *Server) net(ctx context.Context, c *Conn, arg string) Response {
	verb, rest, _ := strings.Cut(strings.TrimSpace(arg), " ")
	switch verb {
	case "":
	case "via":
		if rest != "auto" && rest != "ble" {
			return fail(errors.New("usage: net via auto|ble"))
		}
		c.wifi.setMode(rest)
	case "join", "hotspot":
		var req map[string]string
		if verb == "hotspot" {
			req = map[string]string{"mode": "ap"}
		} else {
			ssid, pass, _ := strings.Cut(rest, "\x00")
			if ssid == "" {
				return fail(errors.New("usage: net join SSID [PASSWORD]"))
			}
			req = map[string]string{"mode": "sta", "ssid": ssid, "pass": pass}
		}
		b, _ := json.Marshal(req)
		if _, err := c.Send(ctx, "net "+string(b)); err != nil {
			return fail(err)
		}
		c.wifi.setMode(TransportMode()) // try the new network soon
	default:
		return fail(errors.New("usage: net [via auto|ble | join SSID [PASSWORD] | hotspot]"))
	}
	reply, err := c.Send(ctx, "net")
	if err != nil {
		return fail(err)
	}
	var board map[string]any
	if json.Unmarshal([]byte(reply), &board) != nil {
		return fail(errors.New("board firmware too old for net: update the board in the app"))
	}
	if board["mode"] == "sta" {
		delete(board, "pass") // your Wi-Fi's password stays out of logs; the hotspot's is needed to join it
	}
	mode, lastErr := c.wifi.state()
	out := map[string]any{"via": c.Via(), "prefer": mode, "board": board}
	if lastErr != "" && c.Via() != "wifi" {
		out["wifi_error"] = lastErr
	}
	return ok(out)
}
