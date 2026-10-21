package intent

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"image"
	_ "image/jpeg"
	_ "image/png"
	"os"
	"strings"
)

// The .esp32intent file (IntentArchive.swift). Fields are in key order: the app writes sorted keys.
const (
	Format    = 1
	Extension = "esp32intent"
	MaxBytes  = 25_000_000
)

type File struct {
	Format  int    `json:"format"`
	Intents []Item `json:"intents"`
	Note    string `json:"note,omitempty"`
}

type Item struct {
	Hints  []string   `json:"hints,omitempty"`
	Icon   *string    `json:"icon,omitempty"`
	Name   string     `json:"name"`
	Prompt string     `json:"prompt"`
	Steps  []FileStep `json:"steps,omitempty"`
}

type FileStep struct {
	Action string  `json:"action"`
	Frame  *string `json:"frame,omitempty"` // base64 JPEG
	Sure   bool    `json:"sure"`
}

// Item is what goes into a file: never the run history or ids; screens only with screenshots.
func (s Store) Item(it Intent, screenshots bool) Item {
	out := Item{Name: it.Name, Prompt: it.Prompt, Icon: it.Icon, Hints: it.Hints}
	if it.Steps != nil {
		out.Steps = []FileStep{}
	}
	for _, st := range it.Steps {
		fs := FileStep{Action: st.Action, Sure: st.Sure}
		if p := s.FramePath(it.ID, st); screenshots && p != "" {
			if data, err := os.ReadFile(p); err == nil {
				fs.Frame = str(base64.StdEncoding.EncodeToString(data))
			}
		}
		out.Steps = append(out.Steps, fs)
	}
	return out
}

// Encode writes the file as the app does: pretty, sorted keys, slashes unescaped.
func Encode(items []Item, note string) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(File{Format: Format, Note: note, Intents: items}); err != nil {
		return nil, err
	}
	return bytes.TrimRight(buf.Bytes(), "\n"), nil
}

// Decode checks the format; drops items without a prompt, steps whose action isn't a JSON object and screens
// that aren't images.
func Decode(data []byte) ([]Item, error) {
	if len(data) > MaxBytes {
		return nil, errors.New("this file is too large")
	}
	var f File
	var keys map[string]json.RawMessage
	if json.Unmarshal(data, &keys) != nil || keys["format"] == nil || keys["intents"] == nil || json.Unmarshal(data, &f) != nil {
		return nil, errors.New("this isn't an ESP32 Agent intent file")
	}
	if f.Format != Format {
		return nil, errors.New("this intent file needs a newer version of esp32agent")
	}
	out := []Item{}
	for _, it := range f.Intents {
		it.Name, it.Prompt = strings.TrimSpace(it.Name), strings.TrimSpace(it.Prompt)
		if it.Prompt == "" {
			continue
		}
		if it.Steps != nil {
			steps := []FileStep{}
			for _, st := range it.Steps {
				var obj map[string]any
				if json.Unmarshal([]byte(st.Action), &obj) != nil || obj == nil {
					continue
				}
				if st.Frame != nil && !isImage(*st.Frame) {
					st.Frame = nil
				}
				steps = append(steps, st)
			}
			it.Steps = steps
		}
		out = append(out, it)
	}
	return out, nil
}

func isImage(b64 string) bool {
	data, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return false
	}
	_, _, err = image.DecodeConfig(bytes.NewReader(data))
	return err == nil
}

func key(name, prompt string) string { return strings.ToLower(name) + "\x1f" + strings.ToLower(prompt) }

// Import adds the items not already saved under the same name and prompt, with new ids, in the file's order
// at the top. Returns the added ones and how many were skipped.
func (s Store) Import(items []Item) ([]Intent, int, error) {
	existing, err := s.Load()
	if err != nil {
		return nil, 0, err
	}
	seen := map[string]bool{}
	for _, it := range existing {
		seen[key(it.Name, it.Prompt)] = true
	}
	added := []Intent{}
	for _, item := range items {
		name := item.Name
		if name == "" {
			name = string([]rune(item.Prompt)[:min(30, len([]rune(item.Prompt)))])
		}
		if seen[key(name, item.Prompt)] {
			continue
		}
		seen[key(name, item.Prompt)] = true
		it := Intent{ID: NewID(), Name: name, Prompt: item.Prompt, Icon: item.Icon, Hints: item.Hints}
		if item.Steps != nil {
			it.Steps = []Step{}
		}
		for i, fs := range item.Steps {
			st := Step{Action: fs.Action, Sure: fs.Sure}
			if fs.Frame != nil {
				if data, err := base64.StdEncoding.DecodeString(*fs.Frame); err == nil {
					if err := s.writeFrame(it.ID, i, data, &st); err != nil {
						return nil, 0, err
					}
				}
			}
			it.Steps = append(it.Steps, st)
		}
		added = append(added, it)
	}
	if len(added) > 0 {
		if err := s.Put(append(append([]Intent{}, added...), existing...)); err != nil {
			return nil, 0, err
		}
	}
	return added, len(items) - len(added), nil
}
