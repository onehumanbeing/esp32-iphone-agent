package audio

import (
	"context"
	"encoding/binary"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func rec(seq uint16, flags byte, frame []byte) []byte {
	b := []byte{byte(seq), byte(seq >> 8), flagAudio | flags}
	if flags&flagEnd != 0 {
		return b
	}
	b = binary.LittleEndian.AppendUint32(b, 1234)
	b = binary.LittleEndian.AppendUint32(b, 99)
	return append(b, frame...)
}

func TestRecordsBecomeSegments(t *testing.T) {
	r, ok := ParseRecord(rec(7, flagStart, []byte{1, 2}))
	if !ok || r.Seq != 7 || !r.Start || r.BoardMs != 1234 || string(r.Frame) != "\x01\x02" {
		t.Fatalf("parse: %+v %v", r, ok)
	}
	if _, ok := ParseRecord([]byte{1, 0, 0, 5}); ok {
		t.Fatal("a video chunk is not audio")
	}
	var s Segmenter
	t0 := time.Unix(100, 0)
	for i, f := range []byte{1, 2, 3} {
		flags := byte(0)
		if i == 0 {
			flags = flagStart
		}
		r, _ := ParseRecord(rec(uint16(i), flags, []byte{f}))
		if s.Add(t0.Add(time.Duration(i)*time.Second), r, false) != nil {
			t.Fatal("segment ended early")
		}
	}
	r, _ = ParseRecord(rec(4, flagEnd, nil)) // seq 3 lost
	seg := s.Add(t0.Add(3*time.Second), r, false)
	if seg == nil || len(seg.Frames) != 3 || seg.Gaps != 1 || seg.End.Sub(seg.Start) != 3*time.Second {
		t.Fatalf("segment: %+v", seg)
	}
	// joined mid-segment, then a stretch longer than MaxSegment is cut
	r, _ = ParseRecord(rec(5, 0, []byte{9}))
	s.Add(t0.Add(10*time.Second), r, false)
	r, _ = ParseRecord(rec(6, 0, []byte{9}))
	if seg := s.Add(t0.Add(10*time.Second+MaxSegment), r, false); seg == nil || len(seg.Frames) != 2 {
		t.Fatalf("long segment not cut: %+v", seg)
	}
}

func TestBlockWording(t *testing.T) {
	now := time.Unix(1000, 0)
	if Block(now, nil, "x") != "" {
		t.Fatal("nothing heard: no block")
	}
	items := []Heard{
		{Start: now.Add(-50 * time.Second), End: now.Add(-40 * time.Second), Text: "old", Final: true},
		{Start: now.Add(-10 * time.Second), End: now.Add(-6 * time.Second), Text: "[zh] 验证码是4729", Final: true},
		{Start: now.Add(-3 * time.Second), End: now.Add(-3 * time.Second), Text: "[en] hi", Final: true},
		{Start: now.Add(-2 * time.Second)},
	}
	want := "Heard (phone audio, last 30 s; how):\n" +
		"- 6 s ago, 4 s long: \"[zh] 验证码是4729\"\n- 3 s ago: \"[en] hi\"\n- now, 2 s so far: (sound, still transcribing)"
	if got := Block(now, items, "how"); got != want {
		t.Fatalf("got\n%s\nwant\n%s", got, want)
	}
}

func TestRecentKeepsAMinute(t *testing.T) {
	var r Recent
	t0 := time.Unix(0, 0)
	r.Begin(t0)
	r.End(t0, t0.Add(time.Second))
	r.Done(t0, "a")
	r.Begin(t0.Add(2 * time.Minute))
	items := r.Items()
	if len(items) != 1 || !items[0].End.IsZero() {
		t.Fatalf("items: %+v", items)
	}
}

func frames(t *testing.T) [][]byte {
	raw, err := os.ReadFile("testdata/tone.eld") // 0.5 s of a 440 Hz tone from the macOS AAC-ELD encoder
	if err != nil {
		t.Fatal(err)
	}
	var out [][]byte
	for len(raw) >= 2 {
		n := int(binary.LittleEndian.Uint16(raw))
		out, raw = append(out, raw[2:2+n]), raw[2+n:]
	}
	return out
}

func TestFFmpegDecodesTheFLV(t *testing.T) {
	ff, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("no ffmpeg")
	}
	l := &Local{FFmpeg: ff}
	dir := t.TempDir()
	in := filepath.Join(dir, "in.flv")
	os.WriteFile(in, FLV(frames(t)), 0o600)
	pcm, err := l.run(context.Background(), ff, "-hide_banner", "-loglevel", "error", "-i", in, "-ac", "1", "-ar", "16000", "-f", "s16le", "-")
	if err != nil {
		t.Fatal(err)
	}
	if secs := float64(len(pcm)) / 2 / 16000; secs < 0.4 || secs > 0.6 {
		t.Fatalf("decoded %.2f s", secs)
	}
	if lv := Level(pcm); lv < -20 || lv > -8 { // a 0.3 tone: about -13.5 dBFS
		t.Fatalf("level %.1f dB", lv)
	}
}

func TestTranscribePicksEnglishOrTheSecondLanguage(t *testing.T) {
	var calls []string
	tone := make([]byte, 3200)
	for i := 0; i < len(tone)/2; i++ {
		binary.LittleEndian.PutUint16(tone[2*i:], uint16(int16(8000*((i/20)%2*2-1))))
	}
	l := &Local{FFmpeg: "ffmpeg", Whisper: "whisper", Model: "m", Second: "zh",
		Run: func(_ context.Context, name string, args ...string) ([]byte, error) {
			if name == "ffmpeg" {
				return tone, nil
			}
			lang := args[3]
			calls = append(calls, lang)
			out := args[len(args)-3] // -of OUT, then --prompt TEXT
			if args[len(args)-2] != "--prompt" {
				out = args[len(args)-1]
			}
			detected := map[string]string{"auto": "ja", "zh": "zh"}[lang]
			return nil, os.WriteFile(out+".json", []byte(`{"result":{"language":"`+detected+`"},"transcription":[{"text":" 你好 "}]}`), 0o600)
		}}
	got, err := l.Transcribe(context.Background(), &Segment{Frames: [][]byte{{1}}})
	if err != nil || got != "[zh] 你好" || strings.Join(calls, ",") != "auto,zh" {
		t.Fatalf("got %q %v, calls %v", got, err, calls)
	}
	silent := &Local{FFmpeg: "ffmpeg", Run: func(context.Context, string, ...string) ([]byte, error) { return make([]byte, 3200), nil }}
	if got, _ := silent.Transcribe(context.Background(), &Segment{Frames: [][]byte{{1}}}); got != "" {
		t.Fatalf("silence: %q", got)
	}
	if err := (&Local{Model: "/nope"}).Check(); err == nil || !strings.Contains(err.Error(), "brew install whisper-cpp") {
		t.Fatalf("check: %v", err)
	}
	if Lang("zh-Hans") != "zh" || Lang("ja_JP") != "ja" || Lang("") != "" {
		t.Fatal("lang")
	}
}
