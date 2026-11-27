package daemon

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	"image/png"
	"io"
	"log"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/config"
	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/pointer"
	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/video"
	"golang.org/x/image/draw"
)

var (
	errMirroring = errors.New("screen mirroring is off: on the iPhone open Control Center > Screen Mirroring > ESP32 Agent")
	errFrozen    = errors.New("video frozen: restart Screen Mirroring on the iPhone (Control Center > Screen Mirroring > Stop Mirroring, then ESP32 Agent)")
)

// staleVideo: Screen Mirroring is on but the iPhone stopped sending frames (#192); fz stays 0 meanwhile.
func staleVideo(age time.Duration) error {
	return fmt.Errorf("video stale: the board has had no frame from Screen Mirroring for %.0f s although the pointer moved "+
		"(the iPhone stopped sending; it often resumes within a minute). Wait and retry, or restart Screen Mirroring "+
		"(Control Center > Screen Mirroring > Stop Mirroring, then ESP32 Agent)", age.Seconds())
}

// whyNotFound turns "pointer not found" into the real cause when the video stalled since t.
func whyNotFound(c *Conn, t time.Time, err error) error {
	if errors.Is(err, pointer.ErrNotFound) {
		if age, ok := c.stalled(t); ok {
			return fmt.Errorf("calibration: no fresh video to find the pointer in: %w", staleVideo(age))
		}
	}
	return err
}

func num(v any) float64 { f, _ := v.(float64); return f }

// videoState explains why there is no usable screen, nil when mirroring streams.
func (s *Server) videoState(ctx context.Context, c *Conn) error {
	for i := 0; i < 30; i++ { // the first status arrives within a second of connecting
		if _, age := c.Status(); age >= 0 {
			break
		}
		if sleepCtx(ctx, 100*time.Millisecond) != nil {
			return ctx.Err()
		}
	}
	st, _ := c.Status()
	if num(st["fz"]) == 1 {
		return errFrozen
	}
	if st["ap"] != "streaming" {
		return errMirroring
	}
	c.mu.Lock()
	ff := c.ffmpeg
	c.mu.Unlock()
	if ff == "" {
		_, err := video.FFmpeg()
		if err == nil {
			err = errors.New("ffmpeg could not decode the video (see daemon.log)")
		}
		return err
	}
	return nil
}

// frame returns the screen as it is after the last action (like the app's VideoFeed.afterAction).
func (s *Server) frame(ctx context.Context, c *Conn) (image.Image, error) {
	if err := s.videoState(ctx, c); err != nil {
		return nil, err
	}
	if c.Frame() == nil && c.Fresh(ctx, time.Time{}, 6*time.Second) == nil {
		// nothing streamed yet (the stream starts at the next keyframe): ask for the current GOP
		sctx, cancel := context.WithTimeout(ctx, 60*time.Second)
		_, err := c.Send(sctx, "snap")
		cancel()
		if err != nil {
			return nil, fmt.Errorf("no video from the board: %w", err)
		}
		if c.Fresh(ctx, time.Time{}, 5*time.Second) == nil {
			return nil, errors.New("no video from the board yet; try again")
		}
	}
	c.mu.Lock()
	acted, shot := c.lastAction, c.lastShot
	c.mu.Unlock()
	if acted.After(shot) {
		c.Settled(ctx, 500*time.Millisecond, 300*time.Millisecond, 3*time.Second)
		c.Fresh(ctx, acted, 1500*time.Millisecond)
	}
	c.mu.Lock()
	c.lastShot = time.Now()
	c.mu.Unlock()
	if st, _ := c.Status(); num(st["fz"]) == 1 {
		return nil, errFrozen
	}
	return c.Frame(), nil
}

func encode(img image.Image, format string, quality int, scale float64, maxSize int) ([]byte, image.Rectangle, error) {
	b := img.Bounds()
	w, h := float64(b.Dx()), float64(b.Dy())
	if scale <= 0 || scale > 1 {
		scale = 1
	}
	if maxSize > 0 && max(w, h)*scale > float64(maxSize) {
		scale = float64(maxSize) / max(w, h)
	}
	if scale < 1 {
		dst := image.NewRGBA(image.Rect(0, 0, max(1, int(w*scale+0.5)), max(1, int(h*scale+0.5))))
		draw.CatmullRom.Scale(dst, dst.Bounds(), img, b, draw.Src, nil)
		img = dst
	}
	var buf bytes.Buffer
	var err error
	switch format {
	case "", "png":
		err = (&png.Encoder{CompressionLevel: png.BestSpeed}).Encode(&buf, img)
	case "jpeg", "jpg":
		if quality <= 0 || quality > 100 {
			quality = 90
		}
		err = jpeg.Encode(&buf, img, &jpeg.Options{Quality: quality})
	default:
		err = fmt.Errorf("format must be png or jpeg")
	}
	return buf.Bytes(), img.Bounds(), err
}

func (s *Server) screenshot(ctx context.Context, c *Conn, req Request) Response {
	img, err := s.frame(ctx, c)
	if err != nil {
		return fail(err)
	}
	data, r, err := encode(img, req.Format, req.Quality, req.Scale, req.MaxSize)
	if err != nil {
		return fail(err)
	}
	format := "png"
	if req.Format == "jpeg" || req.Format == "jpg" {
		format = "jpeg"
	}
	s.recordShot(img, r.Dx(), r.Dy())
	out := map[string]any{"format": format, "data": base64.StdEncoding.EncodeToString(data),
		"width": r.Dx(), "height": r.Dy(), "device": c.ID}
	if age, stale := c.stalledNow(); stale { // marked, not refused: the last picture is still the best there is
		out["stale"], out["video_age_ms"], out["warning"] = true, age.Milliseconds(), staleVideo(age).Error()
	}
	return ok(out)
}

// pointer is the calibrated pointer for the phone mirroring now (status src): each phone has its own calibration
// on this board (#194: one made on an iPhone 12 was used on an iPhone 17 Pro). While the phone is not known, the
// board's own file from before (CLI 0.1.4) is used, and the first phone seen takes it over.
func (c *Conn) pointer(dir string) *pointer.Pointer {
	st, _ := c.Status()
	phone, _ := st["src"].(string)
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ptr == nil || phone != "" && phone != c.phone {
		legacy, old := config.CalibrationPath(dir, c.ID), c.ptr
		file := legacy
		if phone != "" {
			file = config.PhoneCalibrationPath(dir, c.ID, phone)
		}
		p := pointer.New(device{c}, c, file)
		p.Phone = phone
		p.Log = func(s string) { log.Printf("%s: %s", c.ID, s) }
		p.BoardPace = c.boardPace
		switch {
		case phone == "" || p.Calibrated():
		case old != nil && c.phone == "" && old.Calibrated(): // calibrated before the phone was known: this one's
			old.TakeOver(file, phone, legacy)
			p = old
		default:
			p.Adopt(legacy)
		}
		if old != nil && c.phone != "" {
			p.Log(fmt.Sprintf("pointer: the phone changed from %s to %s: using its own calibration", c.phone, phone))
		}
		c.ptr, c.phone = p, phone
	}
	if c.ptr.Calibrated() && !c.paceAsked { // in the background: no wait on a tap
		c.paceAsked = true
		go c.askPace()
	}
	return c.ptr
}

func (c *Conn) boardPace() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.pace
}

// askPace learns how the board paces moves: a calibration made under another pacing no longer fits.
func (c *Conn) askPace() {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	r, err := c.Send(ctx, "pace")
	n, perr := strconv.Atoi(strings.TrimSpace(r))
	c.mu.Lock()
	defer c.mu.Unlock()
	switch {
	case err == nil && perr == nil && n > 0:
		c.pace = n
	case err != nil && strings.Contains(err.Error(), "unknown command"): // firmware before pacing
		c.pace = 1
	case err != nil: // no answer (busy, link lost): ask again with the next gesture
		c.paceAsked = false
	}
}

// size is the screenshot size coordinates refer to: the latest frame, else the AirPlay resolution.
func (c *Conn) size() (float64, float64, error) {
	if f := c.Frame(); f != nil {
		return float64(f.Bounds().Dx()), float64(f.Bounds().Dy()), nil
	}
	st, _ := c.Status()
	if w, h := num(st["w"]), num(st["h"]); w > 0 && h > 0 {
		return w, h, nil
	}
	return 0, 0, errors.New("screen size unknown (no video yet): take a screenshot first")
}

func (s *Server) calibrate(ctx context.Context, c *Conn) Response {
	if err := s.videoState(ctx, c); err != nil {
		return fail(err)
	}
	if _, err := s.frame(ctx, c); err != nil {
		return fail(err)
	}
	p := c.pointer(s.Dir)
	previous, started := p.Snapshot(), time.Now()
	if err := p.Calibrate(ctx); err != nil {
		return fail(whyNotFound(c, started, err))
	}
	out := map[string]any{"span": map[string]int{"w": p.Span.W, "h": p.Span.H}}
	switch e, found, err := p.Verify(ctx, 0.5, 0.62); {
	case err == nil && found && e > pointer.RejectAbove: // wrong (the app's #96); the previous one may still be good
		p.Restore(previous)
		return fail(fmt.Errorf("calibration rejected: its check point missed by %.1f%% (over %.0f%%), so the previous "+
			"calibration was kept; run esp32agent calibrate again", e*100, pointer.RejectAbove*100))
	case err == nil && found:
		out["error"] = e // miss at a check point, fraction of the screen
	default:
		out["warning"] = "the check point was not found, so this calibration is unverified; taps with --aim check it"
	}
	c.mu.Lock()
	c.lastAction = time.Now()
	c.mu.Unlock()
	return ok(out)
}

// textChunk keeps one `type` line well inside a single BLE write.
const textChunk = 160

func (s *Server) io(ctx context.Context, c *Conn, req Request) Response {
	p := c.pointer(s.Dir)
	err := func() error {
		switch req.Cmd {
		case "text":
			typed, err := "", error(nil)
			for rest := pointer.Typeable(req.Text); rest != "" && err == nil; {
				n := min(len(rest), textChunk)
				for n > 0 && !utf8.RuneStart(rest[n-1]) {
					n--
				}
				_, err = p.Type(ctx, rest[:n])
				typed, rest = typed+rest[:n], rest[n:]
			}
			if typed == "" && err == nil {
				err = errors.New("nothing typeable in that text (the board types ASCII only)")
			}
			return err
		case "keys":
			return p.Key(ctx, strings.ToLower(req.Text))
		case "button":
			if !strings.EqualFold(req.Text, "HOME") {
				return fmt.Errorf("button %s not supported on ESP32 Agent (only HOME)", req.Text)
			}
			return p.GoHome(ctx)
		}
		w, h, err := c.size()
		if err != nil {
			return err
		}
		// Calibrate again when the calibration no longer fits (the app's rules), if the screen can be seen; without
		// it an existing calibration is still the best there is. All cheap checks: no wait on a normal tap.
		if why := p.Stale(); why != "" {
			if s.videoState(ctx, c) == nil {
				p.Log("pointer: calibrating: " + why)
				started := time.Now()
				if err := p.Calibrate(ctx); err != nil {
					return whyNotFound(c, started, err)
				}
			} else if !p.Calibrated() {
				return errors.New("pointer not calibrated, and the screen is not visible: turn on Screen Mirroring, then run esp32agent calibrate")
			}
		}
		pt := func(i int) (float64, float64) { return req.Pts[i] / w, req.Pts[i+1] / h }
		switch req.Cmd {
		case "tap":
			x, y := pt(0)
			return p.Tap(ctx, x, y, req.Aim, req.Strict, req.Count)
		case "longpress":
			x, y := pt(0)
			d := time.Duration(req.Ms) * time.Millisecond
			if d <= 0 {
				d = time.Second
			}
			return p.LongPress(ctx, x, y, d)
		case "swipe":
			x1, y1 := pt(0)
			x2, y2 := pt(2)
			return p.Swipe(ctx, x1, y1, x2, y2, true)
		}
		return nil
	}()
	c.mu.Lock()
	c.lastAction = time.Now()
	c.mu.Unlock()
	s.recordAction(c, req, err)
	if err != nil {
		return fail(err)
	}
	out := map[string]any{"message": req.Cmd + " done"}
	switch {
	// #194: say whether anything checked where it landed. "<cmd> done" stays first: scripts match it.
	case req.Cmd == "tap" && req.Aim && p.Seen:
		out["verified"], out["miss"] = true, p.Miss // seen this far off the target, then put on it
	case req.Cmd == "tap" && req.Aim:
		const why = "pointer not found, tapped at the calibrated position"
		out["message"], out["verified"], out["warning"] = "tap done (not verified: "+why+")", false, why
	case req.Cmd == "tap" || req.Cmd == "longpress" || req.Cmd == "swipe":
		out["message"], out["verified"] = req.Cmd+" done (not verified: nothing checked where it landed; take a screenshot, or tap with --aim)", false
	}
	if req.Cmd == "text" && pointer.HasHan(req.Text) {
		out["typed_as"] = pointer.Typeable(req.Text)
		out["note"] = "needs the iPhone's Chinese (pinyin) keyboard; if letters appear, tap the globe key and type again"
	}
	return ok(out)
}

// screencapture streams raw H.264 (Annex-B, from the next keyframe) or MJPEG, after one JSON header line.
func (s *Server) screencapture(ctx context.Context, req Request, w io.Writer) {
	enc := json.NewEncoder(w)
	c, err := s.conn(ctx, req.Device)
	if err == nil {
		err = s.videoState(ctx, c)
	}
	if err == nil && req.Format != "h264" && req.Format != "mjpeg" {
		err = errors.New("format must be h264 or mjpeg")
	}
	if err != nil {
		enc.Encode(fail(err))
		return
	}
	enc.Encode(ok(map[string]string{"format": req.Format}))
	if req.Format == "h264" {
		ch := make(chan video.AU, 256)
		c.mu.Lock()
		c.subs[ch] = true
		config, gop := c.config, append([]video.AU{}, c.gop...)
		c.mu.Unlock()
		defer func() { c.mu.Lock(); delete(c.subs, ch); c.mu.Unlock() }()
		started := len(gop) > 0 && config != nil
		if started {
			w.Write(config)
			for _, au := range gop {
				w.Write(au.Data)
			}
		}
		for {
			select {
			case <-ctx.Done():
				return
			case au := <-ch:
				if !started && au.Flags&(video.IDR|video.Config) == 0 {
					continue
				}
				if !started && au.Flags&video.Config == 0 && config != nil {
					w.Write(config)
				}
				started = true
				if _, err := w.Write(au.Data); err != nil {
					return
				}
			}
		}
	}
	ch := make(chan image.Image, 4)
	c.mu.Lock()
	c.frameSubs[ch] = true
	c.mu.Unlock()
	defer func() { c.mu.Lock(); delete(c.frameSubs, ch); c.mu.Unlock() }()
	for {
		select {
		case <-ctx.Done():
			return
		case img := <-ch:
			data, _, _ := encode(img, "jpeg", req.Quality, 1, 0)
			hdr := fmt.Sprintf("--BoundaryString\r\nContent-Type: image/jpeg\r\nContent-Length: %d\r\n\r\n", len(data))
			if _, err := w.Write(append(append([]byte(hdr), data...), "\r\n"...)); err != nil {
				return
			}
		}
	}
}
