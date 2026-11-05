package ble

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/proto"
)

// Sim runs the simulated board (hardware/tests/sim/cli_sim: the firmware's real cli_link.cpp behind a pipe),
// one process per connection, so a reconnect is a reboot that keeps its NVS file.
// Records on stdin/stdout are [u16 LE length][frame]; length 0 = the link dropped.
type Sim struct {
	Bin    string // cli_sim
	Screen string // H.264 file shown as the mirrored screen (default: screen.h264 next to Bin)
	Log    io.Writer
}

func (s *Sim) Scan(ctx context.Context, d time.Duration) ([]Found, error) {
	if _, err := os.Stat(s.Bin); err != nil {
		return nil, err
	}
	return []Found{{Name: "ESP32 Agent 6AD5", Addr: "sim"}}, nil
}

func (s *Sim) Connect(ctx context.Context, f Found) (proto.Link, error) {
	screen := s.Screen
	if screen == "" {
		screen = filepath.Join(filepath.Dir(s.Bin), "screen.h264")
	}
	cmd := exec.Command(s.Bin, screen)
	if os.Getenv("CLI_SIM_NVS") == "" { // pairings survive "reboots"
		dir, _ := os.UserCacheDir()
		cmd.Env = append(os.Environ(), "CLI_SIM_NVS="+filepath.Join(dir, "esp32agent-sim-nvs"))
	}
	cmd.Stderr = s.Log
	if cmd.Stderr == nil {
		cmd.Stderr = os.Stderr
	}
	in, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	var wmu sync.Mutex
	l := newChanLink(func(p []byte) error {
		if len(p) == 0 || len(p) > 0xffff {
			return errors.New("bad frame size")
		}
		wmu.Lock()
		defer wmu.Unlock()
		_, err := in.Write(append(binary.LittleEndian.AppendUint16(nil, uint16(len(p))), p...))
		return err
	}, func() {
		in.Close()
		cmd.Process.Kill()
		cmd.Wait()
	})
	go func() {
		r := bufio.NewReader(out)
		for {
			var hdr [2]byte
			if _, err := io.ReadFull(r, hdr[:]); err != nil {
				break
			}
			n := binary.LittleEndian.Uint16(hdr[:])
			if n == 0 {
				break // the board dropped the link
			}
			f := make([]byte, n)
			if _, err := io.ReadFull(r, f); err != nil {
				break
			}
			l.deliver(f)
		}
		l.drop()
	}()
	return l, nil
}
