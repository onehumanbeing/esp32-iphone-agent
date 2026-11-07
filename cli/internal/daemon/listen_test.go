package daemon

import (
	"context"
	"encoding/binary"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/audio"
	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/config"
)

func TestListenReadsTheAppsWords(t *testing.T) {
	b := fakeBoard()
	app := `ok {"app":1,"lines":[{"ago":3000,"t":"[zh] 验证码是4729"}]}`
	b.Handle = func(cmd string) string {
		if cmd == "heard" {
			return app
		}
		return "ok"
	}
	c, s := start(t, fakeTransport{b})
	call(t, c, Request{Cmd: "pair"})
	heard := func(text string) string {
		t.Helper()
		r, data := call(t, c, Request{Cmd: "listen", Text: text})
		if r.Status != "ok" {
			t.Fatalf("listen %s: %+v", text, r)
		}
		h, _ := data["heard"].(string)
		return h
	}
	if h := heard(""); !strings.Contains(h, "listening is off") {
		t.Fatalf("off: %q", h)
	}
	if h := heard("on"); !strings.HasPrefix(h, "Heard (phone audio, last 30 s; words transcribed on the phone") ||
		!strings.HasSuffix(h, "\n- 3 s ago: \"[zh] 验证码是4729\"") {
		t.Fatalf("on: %q", h)
	}
	app = `ok {"app":0,"lines":[]}`
	if h := heard(""); !strings.Contains(h, "not sharing what it hears") {
		t.Fatalf("app not sharing: %q", h)
	}
	app = "err unknown command"
	if h := heard(""); !strings.Contains(h, "update the board") {
		t.Fatalf("old firmware: %q", h)
	}
	if r, _ := call(t, c, Request{Cmd: "listen", Text: "mode loud"}); r.Status != "error" {
		t.Fatal("bad mode accepted")
	}
	call(t, c, Request{Cmd: "listen", Text: "lang zh-Hans"})
	raw, _ := os.ReadFile(s.Dir + "/config.json") // kept for the next daemon
	cfg, _ := config.Load()
	if l := cfg.GetListen(); !l.On || l.ListenMode() != "phone" || l.Second != "zh-Hans" || !strings.Contains(string(raw), `"listen"`) {
		t.Fatalf("saved: %+v", l)
	}
	if got := strings.Join(b.Commands, ","); strings.Contains(got, "listen raw on") {
		t.Fatalf("raw audio asked for in mode phone: %s", got)
	}
}

func TestRawAudioIsTranscribedHere(t *testing.T) {
	loud := make([]byte, 3200)
	for i := 0; i < len(loud)/2; i++ {
		binary.LittleEndian.PutUint16(loud[2*i:], uint16(int16(8000*((i/20)%2*2-1))))
	}
	local := &audio.Local{FFmpeg: "ffmpeg", Whisper: "whisper", Model: "m", Second: "zh",
		Run: func(_ context.Context, name string, args ...string) ([]byte, error) {
			if name == "ffmpeg" {
				return loud, nil
			}
			out := args[9] // -m M -l L -f F -np -oj -of OUT
			return nil, os.WriteFile(out+".json", []byte(`{"result":{"language":"en"},"transcription":[{"text":" code 5813"}]}`), 0o600)
		}}
	c := newConn("x", "x", "")
	c.hear = &hearing{work: make(chan *audio.Segment, 4), local: func() *audio.Local { return local }}
	go c.hear.transcribe()
	rec := func(seq uint16, flags byte) []byte {
		b := []byte{byte(seq), 0, 0x80 | flags}
		if flags&2 == 0 {
			b = append(b, 0, 0, 0, 0, 0, 0, 0, 0, 0xAA)
		}
		return b
	}
	c.onAudio(rec(0, 1), false)
	c.onAudio(rec(1, 0), false)
	if items := c.hear.recent.Items(); len(items) != 1 || !items[0].End.IsZero() {
		t.Fatalf("going on: %+v", items)
	}
	c.onAudio(rec(2, 2), false)
	for i := 0; i < 100 && !c.hear.recent.Items()[0].Final; i++ {
		time.Sleep(10 * time.Millisecond)
	}
	got := audio.Block(time.Now(), c.hear.recent.Items(), "here")
	if !strings.Contains(got, `"[en] code 5813"`) {
		t.Fatalf("heard: %q", got)
	}
}
