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
	return ok(map[string]any{"format": format, "data": base64.StdEncoding.EncodeToString(data),
		"width": r.Dx(), "height": r.Dy(), "device": c.ID})
}

func (c *Conn) pointer(dir string) *pointer.Pointer {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ptr == nil {
		c.ptr = pointer.New(device{c}, c, config.CalibrationPath(dir, c.ID))
	}
	return c.ptr
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
	if err := p.Calibrate(ctx); err != nil {
		return fail(err)
	}
	out := map[string]any{"span": map[string]int{"w": p.Span.W, "h": p.Span.H}}
	if e, found, err := p.Verify(ctx, 0.5, 0.62); err == nil && found {
		out["error"] = e // miss at a check point, fraction of the screen
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
		if !p.Calibrated() {
			if s.videoState(ctx, c) != nil {
				return errors.New("pointer not calibrated, and the screen is not visible: turn on Screen Mirroring, then run esp32agent calibrate")
			}
			if err := p.Calibrate(ctx); err != nil {
				return err
			}
		}
		pt := func(i int) (float64, float64) { return req.Pts[i] / w, req.Pts[i+1] / h }
		switch req.Cmd {
		case "tap":
			x, y := pt(0)
			return p.Tap(ctx, x, y, req.Aim, req.Count)
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
	out := map[string]string{"message": req.Cmd + " done"}
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
