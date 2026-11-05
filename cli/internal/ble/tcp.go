package ble

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"strconv"
	"sync"
	"time"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/proto"
)

// WiFiPort is the board's CLI link over Wi-Fi (docs/cli-protocol.md, "Wi-Fi link"): the same frames as over BLE,
// in records [u16 LE length][frame]. A zero-length record is a keepalive; the board drops a link quiet for 6 s.
const WiFiPort = 7202

const keepalive = 2 * time.Second

// DialWiFi opens the board's Wi-Fi link at ip. Sessions on it are opened with HELLO as over BLE; pairing is BLE-only.
func DialWiFi(ctx context.Context, ip string) (proto.Link, error) {
	var d net.Dialer
	nc, err := d.DialContext(ctx, "tcp", net.JoinHostPort(ip, strconv.Itoa(WiFiPort)))
	if err != nil {
		return nil, err
	}
	if tc, ok := nc.(*net.TCPConn); ok {
		tc.SetNoDelay(true)
	}
	return newStreamLink(nc), nil
}

// newStreamLink frames records over a byte stream (a TCP connection).
func newStreamLink(nc net.Conn) proto.Link {
	var wmu sync.Mutex
	done := make(chan struct{})
	write := func(p []byte) error {
		if len(p) > 0xffff {
			return errors.New("bad frame size")
		}
		wmu.Lock()
		defer wmu.Unlock()
		nc.SetWriteDeadline(time.Now().Add(5 * time.Second))
		_, err := nc.Write(append(binary.LittleEndian.AppendUint16(nil, uint16(len(p))), p...))
		return err
	}
	l := newChanLink(func(p []byte) error {
		if len(p) == 0 {
			return errors.New("bad frame size")
		}
		return write(p)
	}, func() {
		close(done)
		nc.Close()
	})
	go func() {
		t := time.NewTicker(keepalive)
		defer t.Stop()
		for {
			select {
			case <-done:
				return
			case <-t.C:
				if write(nil) != nil {
					nc.Close()
					return
				}
			}
		}
	}()
	go func() {
		r := bufio.NewReaderSize(nc, 1<<16)
		for {
			// The board sends status every second: nothing for long is a dead link (Wi-Fi gone, no FIN).
			nc.SetReadDeadline(time.Now().Add(5 * time.Second))
			var hdr [2]byte
			if _, err := io.ReadFull(r, hdr[:]); err != nil {
				break
			}
			n := binary.LittleEndian.Uint16(hdr[:])
			if n == 0 {
				continue
			}
			f := make([]byte, n)
			if _, err := io.ReadFull(r, f); err != nil {
				break
			}
			if !l.deliverWait(f, done) { // a burst (the whole GOP at once) waits instead of losing frames
				break
			}
		}
		l.drop()
		nc.Close()
	}()
	return l
}
