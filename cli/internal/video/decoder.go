package video

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"image"
	"io"
	"os/exec"
	"sync"

	"golang.org/x/image/bmp"
)

// Frame is one decoded picture.
type Frame struct {
	Img image.Image
	TS  uint32 // board ms of its AU
}

// Decoder is an ffmpeg process: Annex-B in, one BMP per picture out. (Not PNG: ffmpeg's PNG encoder holds
// each picture until the next one arrives, a whole frame of latency.)
type Decoder struct {
	cmd    *exec.Cmd
	in     io.WriteCloser
	queue  chan AU
	mu     sync.Mutex
	ts     []uint32 // board times of AUs in flight, oldest first
	stderr bytes.Buffer
	done   chan struct{}
	err    error
}

// FFmpeg finds the ffmpeg binary.
func FFmpeg() (string, error) {
	p, err := exec.LookPath("ffmpeg")
	if err != nil {
		for _, c := range []string{"/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"} {
			if _, e := exec.LookPath(c); e == nil {
				return c, nil
			}
		}
		return "", errors.New("ffmpeg not found: install it (brew install ffmpeg, apt install ffmpeg, winget install ffmpeg)")
	}
	return p, nil
}

// NewDecoder starts ffmpeg; onFrame gets every decoded picture until Close.
func NewDecoder(ffmpeg string, onFrame func(Frame)) (*Decoder, error) {
	// Room for a whole GOP (the board's holds up to 8192 AUs): a new stream starts with it at once, and over Wi-Fi it
	// arrives faster than ffmpeg decodes. 256 overflowed there and the stream waited minutes for the next IDR (2026-11-06).
	d := &Decoder{queue: make(chan AU, 8192), done: make(chan struct{})}
	d.cmd = exec.Command(ffmpeg, "-hide_banner", "-loglevel", "error", "-flags", "low_delay",
		"-probesize", "32", "-analyzeduration", "0", "-threads", "1", "-f", "h264", "-i", "pipe:0", "-fps_mode", "passthrough", "-flush_packets", "1", "-f", "image2pipe", "-c:v", "bmp", "pipe:1")
	d.cmd.Stderr = &d.stderr
	var err error
	if d.in, err = d.cmd.StdinPipe(); err != nil {
		return nil, err
	}
	out, err := d.cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := d.cmd.Start(); err != nil {
		return nil, err
	}
	go d.feed()
	go func() {
		r := bufio.NewReaderSize(out, 1<<20)
		for {
			raw, err := readBMP(r)
			if err != nil {
				break
			}
			img, err := bmp.Decode(bytes.NewReader(raw))
			ts := d.popTS()
			if err == nil {
				onFrame(Frame{Img: img, TS: ts})
			}
		}
		d.err = d.cmd.Wait()
		if s := d.stderr.String(); s != "" {
			d.err = fmt.Errorf("ffmpeg: %s", s)
		}
		close(d.done)
	}()
	return d, nil
}

func (d *Decoder) popTS() uint32 {
	d.mu.Lock()
	defer d.mu.Unlock()
	if len(d.ts) == 0 {
		return 0
	}
	t := d.ts[0]
	d.ts = d.ts[1:]
	return t
}

func (d *Decoder) feed() {
	for au := range d.queue {
		if au.Flags&(IDR|Config) == Config {
			// parameter sets only: no picture comes out of it
		} else {
			d.mu.Lock()
			d.ts = append(d.ts, au.TS)
			if len(d.ts) > 30 { // a picture ffmpeg dropped would skew every later time; never by much
				d.ts = d.ts[len(d.ts)-30:]
			}
			d.mu.Unlock()
		}
		// The trailing delimiter ends the AU for ffmpeg's parser, which otherwise holds it until the next one starts.
		if _, err := d.in.Write(append(au.Data, aud...)); err != nil {
			break
		}
	}
	d.in.Close()
}

// Write queues one AU. A full queue means ffmpeg fell far behind; the AU is dropped and false returned.
func (d *Decoder) Write(au AU) bool {
	select {
	case <-d.done:
		return false
	case d.queue <- au:
		return true
	default:
		return false
	}
}

// Done is closed when ffmpeg exits; Err says why.
func (d *Decoder) Done() <-chan struct{} { return d.done }
func (d *Decoder) Err() error            { return d.err }

func (d *Decoder) Close() {
	defer func() { recover() }() // queue already closed
	close(d.queue)
	if d.cmd.Process != nil {
		d.cmd.Process.Kill()
	}
}

var aud = []byte{0, 0, 0, 1, 9, 0xf0} // access unit delimiter NAL

// readBMP reads one BMP file from a stream of concatenated BMPs.
func readBMP(r *bufio.Reader) ([]byte, error) {
	hdr := make([]byte, 6)
	if _, err := io.ReadFull(r, hdr); err != nil {
		return nil, err
	}
	n := binary.LittleEndian.Uint32(hdr[2:])
	if string(hdr[:2]) != "BM" || n < 54 || n > 64<<20 {
		return nil, errors.New("not a BMP stream")
	}
	buf := make([]byte, n)
	copy(buf, hdr)
	_, err := io.ReadFull(r, buf[6:])
	return buf, err
}
