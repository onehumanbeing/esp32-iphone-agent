package video

import (
	"encoding/binary"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func chunk(seq uint16, flags byte, payload []byte) []byte {
	c := make([]byte, 3)
	binary.LittleEndian.PutUint16(c, seq)
	c[2] = flags
	return append(c, payload...)
}

func ts(ms uint32, data string) []byte {
	b := binary.LittleEndian.AppendUint32(nil, ms)
	return append(b, data...)
}

func TestReassembler(t *testing.T) {
	r := NewReassembler()
	if au := r.Feed(chunk(1, Start|End, ts(5, "P"))); au != nil {
		t.Fatal("a P-frame before any IDR was kept")
	}
	if au := r.Feed(chunk(2, Start|Config|End, ts(10, "SPS"))); au == nil || string(au.Data) != "SPS" || au.TS != 10 {
		t.Fatalf("config AU %+v", au)
	}
	r.Feed(chunk(3, Start|IDR, ts(20, "ab")))
	r.Feed(chunk(4, 0, []byte("cd")))
	au := r.Feed(chunk(5, End, []byte("ef")))
	if au == nil || string(au.Data) != "abcdef" || au.Flags&IDR == 0 || au.TS != 20 {
		t.Fatalf("idr AU %+v", au)
	}
	r.Feed(chunk(6, Bench, []byte("filler")))
	r.Feed(chunk(7, Start, ts(30, "x")))
	if au := r.Feed(chunk(9, End, []byte("y"))); au != nil || r.Gaps != 1 {
		t.Fatalf("AU across a gap: %+v gaps %d", au, r.Gaps)
	}
	if au := r.Feed(chunk(10, Start|End, ts(40, "P"))); au != nil {
		t.Fatal("P-frame after a gap was kept")
	}
	if au := r.Feed(chunk(11, Start|End|IDR, ts(50, "I"))); au == nil {
		t.Fatal("IDR after a gap was dropped")
	}
	if au := r.Feed(chunk(0xFFFF, Start|End|IDR, ts(60, "I"))); au == nil || r.Gaps != 2 {
		t.Fatal("seq jump")
	}
	if au := r.Feed(chunk(0, Start|End, ts(70, "P"))); au == nil || r.Gaps != 2 {
		t.Fatal("seq wrap counted as a gap")
	}
}

// After a gap, a unit the board flags RESUME goes on from the stream's last one: kept without waiting for an IDR.
func TestReassemblerResume(t *testing.T) {
	r := NewReassembler()
	r.Feed(chunk(1, Start|End|IDR, ts(10, "I")))
	r.Feed(chunk(2, Start, ts(20, "a"))) // its END is lost: a failed send on the board
	if au := r.Feed(chunk(4, Start|End, ts(30, "P"))); au != nil || r.Gaps != 1 {
		t.Fatalf("P-frame after a gap: %+v gaps %d", au, r.Gaps)
	}
	if au := r.Feed(chunk(5, Start|End|Resume, ts(20, "ab"))); au == nil || au.TS != 20 || string(au.Data) != "ab" {
		t.Fatalf("resumed AU %+v", au)
	}
	if au := r.Feed(chunk(6, Start|End, ts(30, "P"))); au == nil {
		t.Fatal("the AU after a resumed one was dropped")
	}
}

// splitAUs cuts an Annex-B stream at access unit delimiters (x264 aud=1).
func splitAUs(b []byte) [][]byte {
	var out [][]byte
	start := -1
	for i := 0; i+4 < len(b); i++ {
		if b[i] == 0 && b[i+1] == 0 && b[i+2] == 0 && b[i+3] == 1 && b[i+4]&0x1f == 9 {
			if start >= 0 {
				out = append(out, b[start:i])
			}
			start = i
		}
	}
	return append(out, b[start:])
}

// Real ffmpeg: every AU fed comes out as one picture right away (no reordering delay), with its time.
func TestDecoderOneInOneOut(t *testing.T) {
	ff, err := FFmpeg()
	if err != nil {
		t.Skip(err)
	}
	file := filepath.Join(t.TempDir(), "t.h264")
	gen := exec.Command(ff, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=160x320:rate=5",
		"-frames:v", "8", "-pix_fmt", "yuv420p", "-c:v", "libx264", "-profile:v", "baseline", "-g", "4",
		"-x264-params", "aud=1", "-f", "h264", file)
	if out, err := gen.CombinedOutput(); err != nil {
		t.Skipf("no libx264: %s", out)
	}
	raw, _ := os.ReadFile(file)
	frames := make(chan Frame, 16)
	d, err := NewDecoder(ff, func(f Frame) { frames <- f })
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	for i, au := range splitAUs(raw) {
		d.Write(AU{Flags: Start | End, TS: uint32(100 + i), Data: au[6:]}) // without its AUD, like AirPlay's
		select {
		case f := <-frames:
			if f.TS != uint32(100+i) {
				t.Fatalf("frame %d has time %d", i, f.TS)
			}
			if b := f.Img.Bounds(); b.Dx() != 160 || b.Dy() != 320 {
				t.Fatalf("frame %d is %v", i, b)
			}
		case <-time.After(3 * time.Second):
			t.Fatalf("AU %d gave no picture before the next one", i)
		}
	}
}
