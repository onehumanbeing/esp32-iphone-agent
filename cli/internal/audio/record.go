// Package audio is what the phone plays while it mirrors (AirPlay audio), for `esp32agent listen`: the board's
// audio records cut into segments of sound (raw mode), their transcription on this computer, and the Heard text
// the agent reads (docs/cli-protocol.md, "Phone audio").
package audio

import (
	"encoding/binary"
	"time"
)

// Record is one audio record off stream A: [seq u16 LE][flags][u32 LE board ms][u32 LE RTP ts][AAC-ELD frame],
// flags 0x80 | 1 (a segment's first frame) | 2 (the segment ended; no frame).
type Record struct {
	Seq        uint16
	Start, End bool
	BoardMs    uint32
	Frame      []byte
}

const (
	flagAudio = 0x80
	flagStart = 1
	flagEnd   = 2
)

// ParseRecord reads one record; false if it is not one.
func ParseRecord(b []byte) (Record, bool) {
	if len(b) < 3 || b[2]&flagAudio == 0 {
		return Record{}, false
	}
	r := Record{Seq: binary.LittleEndian.Uint16(b), Start: b[2]&flagStart != 0, End: b[2]&flagEnd != 0}
	if r.End {
		return r, true
	}
	if len(b) <= 11 {
		return Record{}, false
	}
	r.BoardMs = binary.LittleEndian.Uint32(b[3:])
	r.Frame = append([]byte(nil), b[11:]...)
	return r, true
}

// Segment is one stretch of sound: AirPlay's own start and end, cut at MaxSegment so its words come in time.
type Segment struct {
	Start, End time.Time
	Frames     [][]byte
	Gaps       int // records lost inside it
}

// MaxSegment cuts a longer stretch of sound.
const MaxSegment = 30 * time.Second

// Segmenter turns records into segments.
type Segmenter struct {
	cur  *Segment
	last *uint16
}

// Add takes one record (gap: frames were lost before it) and returns a segment it finished, if any.
func (s *Segmenter) Add(now time.Time, r Record, gap bool) *Segment {
	if s.last != nil && r.Seq != *s.last+1 {
		gap = true
	}
	seq := r.Seq
	s.last = &seq
	if gap && s.cur != nil {
		s.cur.Gaps++
	}
	if r.End {
		return s.finish(now)
	}
	var done *Segment
	if r.Start || s.cur == nil {
		done = s.finish(now)
		s.cur = &Segment{Start: now}
	}
	s.cur.Frames = append(s.cur.Frames, r.Frame)
	if now.Sub(s.cur.Start) >= MaxSegment {
		done = s.finish(now)
	}
	return done
}

// Current is the segment going on, if any.
func (s *Segmenter) Current() *Segment { return s.cur }

func (s *Segmenter) finish(now time.Time) *Segment {
	seg := s.cur
	s.cur = nil
	if seg != nil {
		seg.End = now
	}
	return seg
}
