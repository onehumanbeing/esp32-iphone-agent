// Package config keeps the CLI's identity and per-board keys in the user config dir.
package config

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// Dir is os.UserConfigDir()/esp32agent, or $ESP32AGENT_HOME.
func Dir() (string, error) {
	if d := os.Getenv("ESP32AGENT_HOME"); d != "" {
		return d, os.MkdirAll(d, 0o700)
	}
	base, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	d := filepath.Join(base, "esp32agent")
	if err := os.MkdirAll(d, 0o700); err != nil {
		return "", err
	}
	return d, os.Chmod(d, 0o700) // it holds the pairing keys
}

// Board is one paired board.
type Board struct {
	Key  string `json:"key"` // K, hex
	Name string `json:"name,omitempty"`
}

// Listen is `esp32agent listen`: hearing what the phone plays while it mirrors (docs/cli-protocol.md, "Phone audio").
type Listen struct {
	On     bool   `json:"on"`
	Mode   string `json:"mode,omitempty"`   // "phone" (the app's words, default) or "local" (whisper.cpp here)
	Second string `json:"second,omitempty"` // local: the language besides English ("zh"); "" for this computer's
}

// ListenMode is Mode with its default.
func (l Listen) ListenMode() string {
	if l.Mode == "local" {
		return "local"
	}
	return "phone"
}

// GetListen and SetListen guard Listen while the daemon uses it.
func (c *Config) GetListen() Listen {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.Listen
}

func (c *Config) SetListen(l Listen) error {
	c.mu.Lock()
	c.Listen = l
	c.mu.Unlock()
	return c.Save()
}

// Config is config.json. It holds the pairing keys: mode 0600, dir 0700.
type Config struct {
	ClientID string           `json:"client_id"`
	Boards   map[string]Board `json:"boards"` // board id (12 hex) → key
	Listen   Listen           `json:"listen"`
	path     string
	mu       sync.Mutex
}

// Load reads config.json, creating the client id on first use.
func Load() (*Config, error) {
	dir, err := Dir()
	if err != nil {
		return nil, err
	}
	c := &Config{path: filepath.Join(dir, "config.json"), Boards: map[string]Board{}}
	raw, err := os.ReadFile(c.path)
	if err == nil {
		if err := json.Unmarshal(raw, c); err != nil {
			return nil, err
		}
		if c.Boards == nil {
			c.Boards = map[string]Board{}
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if len(c.ClientIDBytes()) != 16 {
		id := make([]byte, 16)
		if _, err := rand.Read(id); err != nil {
			return nil, err
		}
		c.ClientID = hex.EncodeToString(id)
		return c, c.Save()
	}
	return c, nil
}

func (c *Config) ClientIDBytes() []byte {
	b, _ := hex.DecodeString(c.ClientID)
	return b
}

// Save writes the file atomically with mode 0600.
func (c *Config) Save() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	raw, err := json.MarshalIndent(c, "", " ")
	if err != nil {
		return err
	}
	tmp := c.path + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return err
	}
	os.Chmod(tmp, 0o600) // WriteFile keeps the mode of an existing file
	return os.Rename(tmp, c.path)
}

// Key returns K for a board id, nil if not paired.
func (c *Config) Key(boardID []byte) []byte {
	c.mu.Lock()
	defer c.mu.Unlock()
	k, _ := hex.DecodeString(c.Boards[hex.EncodeToString(boardID)].Key)
	if len(k) != 32 {
		return nil
	}
	return k
}

func (c *Config) SetKey(boardID, k []byte, name string) error {
	c.mu.Lock()
	c.Boards[hex.EncodeToString(boardID)] = Board{Key: hex.EncodeToString(k), Name: name}
	c.mu.Unlock()
	return c.Save()
}

func (c *Config) Forget(id string) error {
	c.mu.Lock()
	delete(c.Boards, id)
	c.mu.Unlock()
	os.Remove(CalibrationPath(filepath.Dir(c.path), id))
	return c.Save()
}

// Match finds paired board ids for a selector: a full id, or the 4-hex name suffix ("ESP32 Agent 6AD5").
func (c *Config) Match(sel string) []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	sel = strings.ToLower(sel)
	var out []string
	for id := range c.Boards {
		if id == sel || len(sel) == 4 && strings.HasSuffix(id, sel) {
			out = append(out, id)
		}
	}
	return out
}

// CalibrationPath is where a board's pointer calibration lives.
func CalibrationPath(dir, boardID string) string {
	return filepath.Join(dir, "calibration-"+boardID+".json")
}
