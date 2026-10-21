// Package intent keeps saved intents as the iOS app does (SavedTask in Stores.swift, frames in
// intent-frames/<id>/sNN.jpg) and reads and writes its .esp32intent files (IntentArchive.swift).
package intent

import (
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Step is RecordedStep: the action as a JSON object string (0-1000 screen units), trusted or not, its screen.
type Step struct {
	Action string  `json:"action"`
	Sure   bool    `json:"sure"`
	Frame  *string `json:"frame,omitempty"`
}

// RunStat is one run of the intent; Date is seconds since 2001-01-01, as Swift encodes a Date.
type RunStat struct {
	Run     string  `json:"run"`
	OK      bool    `json:"ok"`
	Seconds float64 `json:"seconds"`
	Date    float64 `json:"date"`
}

// Intent is SavedTask.
type Intent struct {
	ID      string    `json:"id"`
	Name    string    `json:"name"`
	Prompt  string    `json:"prompt"`
	Icon    *string   `json:"icon,omitempty"`
	Hints   []string  `json:"hints,omitempty"`
	RefRun  string    `json:"refRun,omitempty"`
	Steps   []Step    `json:"steps,omitempty"`
	History []RunStat `json:"history,omitempty"`
}

// Store is intents.json (newest first, as the app lists them) and the frames next to it.
type Store struct{ Dir string } // the config dir

func (s Store) path() string { return filepath.Join(s.Dir, "intents.json") }

// Frames is the folder of one intent's reference screens.
func (s Store) Frames(id string) string { return filepath.Join(s.Dir, "intent-frames", id) }

// FramePath is a step's screen file, "" when it has none or the name is unsafe.
func (s Store) FramePath(id string, st Step) string {
	if st.Frame == nil || *st.Frame == "" || strings.ContainsAny(*st.Frame, `/\`) || strings.Contains(*st.Frame, "..") {
		return ""
	}
	return filepath.Join(s.Frames(id), *st.Frame)
}

func (s Store) Load() ([]Intent, error) {
	raw, err := os.ReadFile(s.path())
	if errors.Is(err, os.ErrNotExist) {
		return []Intent{}, nil
	}
	if err != nil {
		return nil, err
	}
	var out []Intent
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, fmt.Errorf("intents.json: %w", err)
	}
	return out, nil
}

func (s Store) Put(items []Intent) error {
	raw, err := json.MarshalIndent(items, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path() + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path())
}

// Find is the intent with this id, else the one with this name (case-insensitive).
func Find(items []Intent, key string) (int, error) {
	key = strings.TrimSpace(key)
	for i, it := range items {
		if strings.EqualFold(it.ID, key) {
			return i, nil
		}
	}
	found := -1
	for i, it := range items {
		if strings.EqualFold(it.Name, key) {
			if found >= 0 {
				return -1, fmt.Errorf("several intents are named %q: use the id", key)
			}
			found = i
		}
	}
	if found < 0 {
		return -1, fmt.Errorf("no intent %q (see esp32agent intent list)", key)
	}
	return found, nil
}

// Delete removes an intent and its frames.
func (s Store) Delete(key string) (Intent, error) {
	items, err := s.Load()
	if err != nil {
		return Intent{}, err
	}
	i, err := Find(items, key)
	if err != nil {
		return Intent{}, err
	}
	gone := items[i]
	if err := s.Put(append(items[:i:i], items[i+1:]...)); err != nil {
		return Intent{}, err
	}
	os.RemoveAll(s.Frames(gone.ID))
	return gone, nil
}

// NewID is a random (v4) UUID, uppercase like Swift's UUID.uuidString.
func NewID() string {
	var b [16]byte
	rand.Read(b[:])
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return strings.ToUpper(fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]))
}

func str(s string) *string { return &s }
