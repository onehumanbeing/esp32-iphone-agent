// Package ble finds boards and opens links to their cli service: over BLE, or to the simulated board
// (hardware/tests/sim) when ESP32AGENT_SIM is set.
package ble

import (
	"context"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/proto"
)

// Found is one advertising board.
type Found struct {
	Name string
	Addr string
	RSSI int16
	ref  any
}

// Suffix is the 4 hex digits of the name, "ESP32 Agent 6AD5" → "6ad5" (the board id's last two bytes).
func (f Found) Suffix() string {
	i := strings.LastIndexByte(f.Name, ' ')
	if i < 0 || len(f.Name)-i-1 != 4 {
		return ""
	}
	return strings.ToLower(f.Name[i+1:])
}

// Transport finds boards and connects to them.
type Transport interface {
	Scan(ctx context.Context, d time.Duration) ([]Found, error)
	Connect(ctx context.Context, f Found) (proto.Link, error)
}

// Default is the simulated board when ESP32AGENT_SIM names its binary, BLE otherwise.
func Default() Transport {
	if sim := os.Getenv("ESP32AGENT_SIM"); sim != "" {
		return &Sim{Bin: sim, Screen: os.Getenv("ESP32AGENT_SIM_SCREEN")}
	}
	return &BLE{}
}

// chanLink is a Link fed by a callback: notifies go into a buffered channel.
type chanLink struct {
	ch    chan []byte
	once  sync.Once
	mu    sync.Mutex
	shut  bool
	write func([]byte) error
	close func()
}

func newChanLink(write func([]byte) error, close func()) *chanLink {
	return &chanLink{ch: make(chan []byte, 8192), write: write, close: close}
}

// deliver hands a frame to the reader; a full buffer drops it (video recovers at the next IDR, a control
// frame lost this way ends the session through its counter).
func (l *chanLink) deliver(f []byte) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.shut {
		return
	}
	select {
	case l.ch <- f:
	default:
	}
}

// deliverWait hands a frame to the reader and waits while the buffer is full (a TCP link: the stack then slows the
// board down, nothing is lost). False once the link is gone or done closes.
func (l *chanLink) deliverWait(f []byte, done <-chan struct{}) bool {
	for {
		l.mu.Lock()
		if l.shut {
			l.mu.Unlock()
			return false
		}
		select {
		case l.ch <- f:
			l.mu.Unlock()
			return true
		default:
		}
		l.mu.Unlock()
		select {
		case <-done:
			return false
		case <-time.After(5 * time.Millisecond):
		}
	}
}

func (l *chanLink) Recv() <-chan []byte { return l.ch }

func (l *chanLink) Write(f []byte) error {
	l.mu.Lock()
	shut := l.shut
	l.mu.Unlock()
	if shut {
		return proto.ErrSession
	}
	return l.write(f)
}

// drop marks the link gone (the board or the OS dropped it).
func (l *chanLink) drop() {
	l.mu.Lock()
	defer l.mu.Unlock()
	if !l.shut {
		l.shut = true
		close(l.ch)
	}
}

func (l *chanLink) Close() error {
	l.once.Do(func() {
		l.drop()
		if l.close != nil {
			l.close()
		}
	})
	return nil
}
