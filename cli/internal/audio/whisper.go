package audio

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Local transcribes segments on this computer with whisper.cpp: English and the second language, as the app.
type Local struct {
	FFmpeg, Whisper, Model string
	Second                 string // whisper language code ("zh"), "" for English only
	// Run runs a tool, its stdout returned (tests replace it); nil: exec.
	Run func(ctx context.Context, name string, args ...string) ([]byte, error)
}

// QuietDB: a segment this quiet has no words (whisper makes some up from silence).
const QuietDB = -50.0

// ModelPath is where `listen mode local` looks for the model.
func ModelPath(dir string) string { return filepath.Join(dir, "whisper", "ggml-base.bin") }

// FindWhisper is whisper.cpp's command line tool on PATH ("" if none).
func FindWhisper() string {
	for _, name := range []string{"whisper-cli", "whisper-cpp"} {
		if p, err := exec.LookPath(name); err == nil {
			return p
		}
	}
	return ""
}

// Lang is a setting such as "zh-Hans" or "ja_JP" as a whisper language code ("zh", "ja"); "" stays "".
func Lang(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	if i := strings.IndexAny(s, "-_"); i >= 0 {
		s = s[:i]
	}
	return s
}

// Check says what is missing to transcribe here, with how to get it.
func (l *Local) Check() error {
	var miss []string
	if l.FFmpeg == "" {
		miss = append(miss, "ffmpeg (brew install ffmpeg)")
	}
	if l.Whisper == "" {
		miss = append(miss, "whisper.cpp (brew install whisper-cpp)")
	}
	if _, err := os.Stat(l.Model); err != nil {
		miss = append(miss, fmt.Sprintf("the model %s (curl -L --create-dirs -o '%s' https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin)", l.Model, l.Model))
	}
	if len(miss) > 0 {
		return errors.New("transcribing on this computer needs " + strings.Join(miss, ", "))
	}
	return nil
}

// Transcribe returns a segment's words ("" for none or quiet sound), labelled "[zh] …" with a second language.
func (l *Local) Transcribe(ctx context.Context, seg *Segment) (string, error) {
	if len(seg.Frames) == 0 {
		return "", nil
	}
	dir, err := os.MkdirTemp("", "esp32agent-audio")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(dir)
	in := filepath.Join(dir, "in.flv")
	if err := os.WriteFile(in, FLV(seg.Frames), 0o600); err != nil {
		return "", err
	}
	pcm, err := l.run(ctx, l.FFmpeg, "-hide_banner", "-loglevel", "error", "-i", in, "-ac", "1", "-ar", "16000", "-f", "s16le", "-")
	if err != nil {
		return "", fmt.Errorf("ffmpeg: %w", err)
	}
	if Level(pcm) < QuietDB {
		return "", nil
	}
	wav := filepath.Join(dir, "in.wav")
	if err := os.WriteFile(wav, WAV(pcm, 16000), 0o600); err != nil {
		return "", err
	}
	lang, text, err := l.whisper(ctx, dir, wav, "auto")
	if err != nil {
		return "", err
	}
	if lang != "en" && lang != l.Second { // another language: read it as the one it most likely is of the two
		want := l.Second
		if want == "" {
			want = "en"
		}
		if lang, text, err = l.whisper(ctx, dir, wav, want); err != nil {
			return "", err
		}
	}
	if text == "" || l.Second == "" {
		return text, nil
	}
	return "[" + lang + "] " + text, nil
}

func (l *Local) whisper(ctx context.Context, dir, wav, lang string) (string, string, error) {
	out := filepath.Join(dir, "out-"+lang)
	args := []string{"-m", l.Model, "-l", lang, "-f", wav, "-np", "-oj", "-of", out}
	if l.Second == "zh" { // whisper writes Chinese in traditional characters unless shown simplified ones
		args = append(args, "--prompt", "以下是普通话的句子。")
	}
	if _, err := l.run(ctx, l.Whisper, args...); err != nil {
		return "", "", fmt.Errorf("whisper: %w", err)
	}
	raw, err := os.ReadFile(out + ".json")
	if err != nil {
		return "", "", fmt.Errorf("whisper: %w", err)
	}
	var r struct {
		Result struct {
			Language string `json:"language"`
		} `json:"result"`
		Transcription []struct {
			Text string `json:"text"`
		} `json:"transcription"`
	}
	if err := json.Unmarshal(raw, &r); err != nil {
		return "", "", fmt.Errorf("whisper output: %w", err)
	}
	var b strings.Builder
	for _, s := range r.Transcription {
		b.WriteString(s.Text)
	}
	got := r.Result.Language
	if got == "" {
		got = lang
	}
	return got, strings.TrimSpace(b.String()), nil
}

func (l *Local) run(ctx context.Context, name string, args ...string) ([]byte, error) {
	if l.Run != nil {
		return l.Run(ctx, name, args...)
	}
	var out, errb bytes.Buffer
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("%v: %s", err, strings.TrimSpace(errb.String()))
	}
	return out.Bytes(), nil
}

// Level is the loudness of 16-bit mono PCM in dBFS (-160 for silence).
func Level(pcm []byte) float64 {
	n := len(pcm) / 2
	if n == 0 {
		return -160
	}
	var sum float64
	for i := 0; i < n; i++ {
		v := float64(int16(binary.LittleEndian.Uint16(pcm[2*i:]))) / 32768
		sum += v * v
	}
	rms := math.Sqrt(sum / float64(n))
	if rms == 0 {
		return -160
	}
	return math.Max(-160, 20*math.Log10(rms))
}

// WAV wraps 16-bit mono PCM.
func WAV(pcm []byte, rate uint32) []byte {
	h := make([]byte, 0, 44+len(pcm))
	h = append(h, "RIFF"...)
	h = binary.LittleEndian.AppendUint32(h, uint32(36+len(pcm)))
	h = append(h, "WAVEfmt "...)
	h = binary.LittleEndian.AppendUint32(h, 16)
	h = binary.LittleEndian.AppendUint16(h, 1) // PCM
	h = binary.LittleEndian.AppendUint16(h, 1) // mono
	h = binary.LittleEndian.AppendUint32(h, rate)
	h = binary.LittleEndian.AppendUint32(h, rate*2)
	h = binary.LittleEndian.AppendUint16(h, 2)
	h = binary.LittleEndian.AppendUint16(h, 16)
	h = append(h, "data"...)
	h = binary.LittleEndian.AppendUint32(h, uint32(len(pcm)))
	return append(h, pcm...)
}
