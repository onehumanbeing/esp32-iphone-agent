// Package daemon holds the BLE sessions: the first CLI command starts `esp32agent daemon`, and every command
// reaches it over a unix socket in the config dir. It exits after 10 minutes without requests.
package daemon

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/ble"
	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/config"
	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/history"
	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/proto"
	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/video"
)

// Request is one command from the CLI.
type Request struct {
	Cmd     string    `json:"cmd"`
	Device  string    `json:"device,omitempty"`
	Pts     []float64 `json:"pts,omitempty"` // screenshot pixel coordinates
	Text    string    `json:"text,omitempty"`
	Ms      int       `json:"ms,omitempty"`
	Format  string    `json:"format,omitempty"`
	Quality int       `json:"quality,omitempty"`
	Scale   float64   `json:"scale,omitempty"`
	MaxSize int       `json:"max_size,omitempty"`
	Aim     bool      `json:"aim,omitempty"`
}

// Response is the CLI's JSON output, as mobilecli's: {"status":"ok","data":…} or {"status":"error","error":"…"}.
type Response struct {
	Status string `json:"status"`
	Data   any    `json:"data,omitempty"`
	Error  string `json:"error,omitempty"`
}

func ok(data any) Response    { return Response{Status: "ok", Data: data} }
func fail(err error) Response { return Response{Status: "error", Error: err.Error()} }

type Server struct {
	Transport ble.Transport
	Config    *config.Config
	Dir       string
	Version   string
	Idle      time.Duration // exit after this long without requests (0 = never)
	ScanTime  time.Duration

	mu     sync.Mutex
	conns  map[string]*Conn
	last   time.Time
	active int
	linkMu sync.Mutex // one scan or connect at a time
	stop   chan struct{}
	once   sync.Once
	hist   *history.Recorder
}

func (s *Server) Serve(l net.Listener) error {
	s.conns, s.last, s.stop = map[string]*Conn{}, time.Now(), make(chan struct{})
	if s.ScanTime == 0 {
		s.ScanTime = 4 * time.Second
	}
	go func() {
		<-s.stop
		l.Close()
	}()
	if s.Idle > 0 {
		go s.idle()
	}
	for {
		nc, err := l.Accept()
		if err != nil {
			select {
			case <-s.stop:
				s.closeAll()
				return nil
			default:
				return err
			}
		}
		go s.handle(nc)
	}
}

func (s *Server) Stop() { s.once.Do(func() { close(s.stop) }) }

func (s *Server) closeAll() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, c := range s.conns {
		c.close()
	}
}

func (s *Server) idle() {
	for {
		select {
		case <-s.stop:
			return
		case <-time.After(10 * time.Second):
		}
		s.mu.Lock()
		quiet := s.active == 0 && time.Since(s.last) > s.Idle
		s.mu.Unlock()
		if quiet {
			log.Printf("idle for %v, exiting", s.Idle)
			s.Stop()
			return
		}
	}
}

func (s *Server) touch(delta int) {
	s.mu.Lock()
	s.last, s.active = time.Now(), s.active+delta
	s.mu.Unlock()
}

func (s *Server) handle(nc net.Conn) {
	defer nc.Close()
	s.touch(1)
	defer s.touch(-1)
	var req Request
	if err := json.NewDecoder(bufio.NewReader(nc)).Decode(&req); err != nil {
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { // the CLI went away (Ctrl-C): stop what it asked for
		io.Copy(io.Discard, nc)
		cancel()
	}()
	if req.Cmd == "screencapture" {
		s.screencapture(ctx, req, nc)
		return
	}
	resp := s.Do(ctx, req)
	json.NewEncoder(nc).Encode(resp)
	if req.Cmd == "stop" {
		s.Stop()
	}
}

// Do runs one request.
func (s *Server) Do(ctx context.Context, req Request) Response {
	switch req.Cmd {
	case "version":
		return ok(map[string]string{"version": s.Version})
	case "stop":
		return ok(map[string]string{"message": "daemon stopping"})
	case "devices":
		return s.devices(ctx)
	case "pair":
		return s.pair(ctx, req.Device)
	case "unpair":
		return s.unpair(req.Device)
	}
	c, err := s.conn(ctx, req.Device)
	if err != nil {
		return fail(err)
	}
	switch req.Cmd {
	case "info":
		st, age := c.Status()
		st["id"], st["name"] = c.ID, c.Name
		if age >= 0 {
			st["age_ms"] = age.Milliseconds()
		}
		return ok(st)
	case "screenshot":
		return s.screenshot(ctx, c, req)
	case "calibrate":
		return s.calibrate(ctx, c)
	case "tap", "longpress", "swipe", "text", "keys", "button":
		return s.io(ctx, c, req)
	case "send": // debugging: one raw board command; afterwards the pointer position is unknown
		reply, err := c.Send(ctx, req.Text)
		c.pointer(s.Dir).Forget()
		if err != nil {
			return fail(err)
		}
		return ok(map[string]string{"reply": reply})
	}
	return fail(fmt.Errorf("unknown command %q", req.Cmd))
}

type deviceInfo struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Platform  string `json:"platform"`
	Type      string `json:"type"`
	State     string `json:"state"`
	Paired    bool   `json:"paired"`
	Connected bool   `json:"connected"`
}

func (s *Server) devices(ctx context.Context) Response {
	list := []deviceInfo{}
	seen := map[string]bool{}
	s.mu.Lock()
	for _, c := range s.conns {
		if c.connected() {
			list = append(list, deviceInfo{c.ID, c.Name, "ios", "esp32agent", "online", true, true})
			seen[c.ID[8:]] = true
		}
	}
	s.mu.Unlock()
	found, err := s.scan(ctx)
	if err != nil {
		return fail(err)
	}
	for _, f := range found {
		suf := f.Suffix()
		if seen[suf] && suf != "" {
			continue
		}
		d := deviceInfo{ID: suf, Name: f.Name, Platform: "ios", Type: "esp32agent", State: "online"}
		if ids := s.Config.Match(suf); suf != "" && len(ids) == 1 {
			d.ID, d.Paired = ids[0], true
		}
		list = append(list, d)
	}
	return ok(map[string]any{"devices": list})
}

func (s *Server) scan(ctx context.Context) ([]ble.Found, error) {
	s.linkMu.Lock()
	defer s.linkMu.Unlock()
	return s.Transport.Scan(ctx, s.ScanTime)
}

// matches: a selector is a full board id or its last 4 hex digits; a board whose name was not seen matches any.
func matches(f ble.Found, sel string) bool {
	if sel == "" || f.Suffix() == "" {
		return true
	}
	sel = strings.ToLower(sel)
	return f.Suffix() == sel || len(sel) == 12 && sel[8:] == f.Suffix()
}

// pick chooses the board to connect to: the one matching sel, else the only one, else the only paired one.
func (s *Server) pick(ctx context.Context, sel string, wantPaired bool) (ble.Found, error) {
	found, err := s.scan(ctx)
	if err != nil {
		return ble.Found{}, err
	}
	var cand, paired []ble.Found
	for _, f := range found {
		if matches(f, sel) {
			cand = append(cand, f)
			if f.Suffix() != "" && len(s.Config.Match(f.Suffix())) > 0 {
				paired = append(paired, f)
			}
		}
	}
	switch {
	case len(cand) == 0 && sel != "":
		return ble.Found{}, fmt.Errorf("board %s not found (is it plugged into the iPhone and near this computer?)", sel)
	case len(cand) == 0:
		return ble.Found{}, errors.New("board not found: no \"ESP32 Agent\" nearby (plugged into the iPhone? firmware with CLI support?)")
	case len(cand) == 1:
		return cand[0], nil
	case wantPaired && len(paired) == 1:
		return paired[0], nil
	}
	var names []string
	for _, f := range cand {
		names = append(names, f.Suffix())
	}
	return ble.Found{}, fmt.Errorf("several boards found (%s): pass --device <id> or set ESP32AGENT_DEVICE", strings.Join(names, ", "))
}

func explain(err error) error {
	var be proto.BoardError
	if errors.As(err, &be) && be == "not paired" {
		return errors.New("not paired with this board: run esp32agent pair (within 3 minutes of plugging the board in)")
	}
	return err
}

// conn returns the connected board for sel, connecting (scan + HELLO) if needed.
func (s *Server) conn(ctx context.Context, sel string) (*Conn, error) {
	var live []*Conn
	s.mu.Lock()
	for id, c := range s.conns {
		if c.connected() && (sel == "" || strings.EqualFold(id, sel) || len(sel) == 4 && strings.EqualFold(id[8:], sel)) {
			live = append(live, c)
		}
	}
	s.mu.Unlock()
	if len(live) == 1 {
		return live[0], nil
	}
	f, err := s.pick(ctx, sel, true)
	if err != nil {
		return nil, err
	}
	return s.open(ctx, f, sel, nil)
}

// open connects to f and starts a session. l: an already open link (after PAIR).
func (s *Server) open(ctx context.Context, f ble.Found, sel string, l proto.Link) (*Conn, error) {
	s.linkMu.Lock()
	defer s.linkMu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	var err error
	if l == nil {
		// macOS's first connect after a peripheral reboots, or after the daemon restarts, sometimes times out
		// discovering services (2026-10-21); the second goes through.
		if l, err = s.Transport.Connect(ctx, f); err != nil && ctx.Err() == nil {
			l, err = s.Transport.Connect(ctx, f)
		}
		if err != nil {
			return nil, err
		}
	}
	sess, err := proto.Hello(ctx, l, s.Config.ClientIDBytes(), s.Config.Key)
	if err != nil {
		l.Close()
		return nil, explain(err)
	}
	id := idHex(sess.BoardID)
	if sel != "" && !strings.EqualFold(id, sel) && !(len(sel) == 4 && strings.EqualFold(id[8:], sel)) {
		sess.Close()
		return nil, fmt.Errorf("board %s not found (found %s)", sel, id)
	}
	s.mu.Lock()
	c := s.conns[id]
	if c == nil {
		ff, _ := video.FFmpeg()
		c = newConn(id, f.Name, ff)
		s.conns[id] = c
	}
	s.mu.Unlock()
	if err := c.attach(sess); err != nil {
		c.detach(sess, err)
		return nil, fmt.Errorf("board %s did not answer: %w", id, err)
	}
	log.Printf("%s: connected (%s)", id, f.Name)
	return c, nil
}

func (s *Server) pair(ctx context.Context, sel string) Response {
	f, err := s.pick(ctx, sel, false)
	if err != nil {
		return fail(err)
	}
	pctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	s.linkMu.Lock()
	l, err := s.Transport.Connect(pctx, f)
	if err != nil {
		s.linkMu.Unlock()
		return fail(err)
	}
	k, boardID, err := proto.Pair(pctx, l, s.Config.ClientIDBytes())
	s.linkMu.Unlock()
	if err != nil {
		l.Close()
		return fail(err)
	}
	if err := s.Config.SetKey(boardID, k, f.Name); err != nil {
		l.Close()
		return fail(err)
	}
	s.mu.Lock()
	if old := s.conns[idHex(boardID)]; old != nil {
		old.close()
	}
	s.mu.Unlock()
	c, err := s.open(ctx, f, "", l)
	if err != nil {
		return fail(fmt.Errorf("paired, but the session failed: %w", err))
	}
	return ok(map[string]any{"id": c.ID, "name": c.Name, "message": "paired"})
}

func (s *Server) unpair(sel string) Response {
	var ids []string
	if sel == "" {
		for id := range s.Config.Boards {
			ids = append(ids, id)
		}
	} else {
		ids = s.Config.Match(sel)
	}
	if len(ids) != 1 {
		return fail(fmt.Errorf("unpair: %d paired boards match; pass --device <id>", len(ids)))
	}
	s.mu.Lock()
	if c := s.conns[ids[0]]; c != nil {
		c.close()
		delete(s.conns, ids[0])
	}
	s.mu.Unlock()
	if err := s.Config.Forget(ids[0]); err != nil {
		return fail(err)
	}
	return ok(map[string]string{"id": ids[0], "message": "forgotten here; the board keeps its key until it is unpaired in the app"})
}

// Listen opens the daemon socket (AF_UNIX, also on Windows 10+).
func Listen(dir string) (net.Listener, error) {
	path := SocketPath(dir)
	if c, err := net.DialTimeout("unix", path, time.Second); err == nil {
		c.Close()
		return nil, errors.New("a daemon is already running")
	}
	os.Remove(path)
	return net.Listen("unix", path)
}
