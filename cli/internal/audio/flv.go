package audio

import "encoding/binary"

// Config is the mirroring stream's AudioSpecificConfig: AAC-ELD, 44.1 kHz, stereo, 480-sample frames.
var Config = []byte{0xF8, 0xE8, 0x50, 0x00}

// FrameMs is one frame's length.
const FrameMs = 480.0 * 1000 / 44100

// FLV wraps raw AAC-ELD frames so ffmpeg can read them: ADTS can't carry ELD, and FLV is the smallest container
// that carries the AudioSpecificConfig (its AAC sequence header) and raw frames as they are.
func FLV(frames [][]byte) []byte {
	out := []byte{'F', 'L', 'V', 1, 0x04, 0, 0, 0, 9, 0, 0, 0, 0} // audio only; first PreviousTagSize 0
	tag := func(ms uint32, body []byte) {
		h := []byte{8, byte(len(body) >> 16), byte(len(body) >> 8), byte(len(body)),
			byte(ms >> 16), byte(ms >> 8), byte(ms), byte(ms >> 24), 0, 0, 0}
		out = append(append(out, h...), body...)
		out = binary.BigEndian.AppendUint32(out, uint32(11+len(body)))
	}
	tag(0, append([]byte{0xAF, 0}, Config...)) // AAC, 44 kHz, 16-bit, stereo; sequence header
	for i, f := range frames {
		tag(uint32(float64(i)*FrameMs), append([]byte{0xAF, 1}, f...))
	}
	return out
}
