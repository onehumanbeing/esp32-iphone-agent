// Package video rebuilds H.264 access units from the board's video chunks and decodes them with ffmpeg.
package video

import "encoding/binary"

// Chunk flags (docs/ble-protocol.md, "video").
const (
	Start  = 1
	End    = 2
	IDR    = 4
	Config = 8
	Bench  = 16
	Snap   = 32
	Resume = 64 // the board goes on from the stream's last unit (`stream on at`, a retried send): no gap for the decoder
)

// AU is one access unit, Annex-B.
type AU struct {
	Flags byte
	TS    uint32 // board ms when it got the AU
	Data  []byte
}

// Reassembler rebuilds access units from chunks; after a gap it waits for the next CONFIG/IDR, or a RESUME unit.
type Reassembler struct {
	expect  int // next seq, -1 = unknown
	cur     *AU
	waiting bool
	Gaps    int
}

func NewReassembler() *Reassembler { return &Reassembler{expect: -1, waiting: true} }

// Lost marks frames lost below the chunk layer (a counter gap on stream V).
func (r *Reassembler) Lost() {
	r.Gaps++
	r.cur, r.waiting = nil, true
}

// Feed takes one chunk [seq u16 LE][flags][payload] and returns a finished AU, if any.
func (r *Reassembler) Feed(chunk []byte) *AU {
	if len(chunk) < 3 {
		return nil
	}
	seq := int(binary.LittleEndian.Uint16(chunk))
	flags, payload := chunk[2], chunk[3:]
	if r.expect >= 0 && seq != r.expect {
		r.Lost()
	}
	r.expect = (seq + 1) & 0xFFFF
	if flags&Bench != 0 {
		return nil
	}
	if flags&Start != 0 {
		if r.waiting && flags&(Config|IDR|Resume) == 0 || len(payload) < 4 {
			r.cur = nil
			return nil
		}
		r.waiting = false
		r.cur = &AU{Flags: flags, TS: binary.LittleEndian.Uint32(payload), Data: append([]byte{}, payload[4:]...)}
	} else if r.cur != nil {
		r.cur.Data = append(r.cur.Data, payload...)
	}
	if flags&End != 0 && r.cur != nil {
		au := r.cur
		au.Flags |= flags
		r.cur = nil
		return au
	}
	return nil
}
