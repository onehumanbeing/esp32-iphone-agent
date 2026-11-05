package ble

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/proto"
	"tinygo.org/x/bluetooth"
)

const base = "6e400001-a9e8-4b1b-9c39-6d6f8a3c"

var (
	svcUUID  = mustUUID(base + "0010")
	inUUID   = mustUUID(base + "0011")
	outUUID  = mustUUID(base + "0012")
	inNRUUID = mustUUID(base + "0013") // cli_in as write commands (firmware 0.2.2+)
)

func mustUUID(s string) bluetooth.UUID {
	u, err := bluetooth.ParseUUID(s)
	if err != nil {
		panic(err)
	}
	return u
}

// BLE talks to boards over the OS Bluetooth stack (CoreBluetooth, BlueZ, WinRT). No OS pairing: the board's
// cli service is reached on its random static address, which changes every boot, so no bond ever forms.
type BLE struct {
	once    sync.Once
	err     error
	adapter *bluetooth.Adapter
	mu      sync.Mutex // one scan or connect at a time
	links   sync.Map   // address → *chanLink
}

func (b *BLE) enable() error {
	b.once.Do(func() {
		b.adapter = bluetooth.DefaultAdapter
		b.adapter.SetConnectHandler(func(d bluetooth.Device, connected bool) {
			if l, ok := b.links.Load(d.Address.String()); ok && !connected {
				l.(*chanLink).drop()
			}
		})
		if err := b.adapter.Enable(); err != nil {
			b.err = fmt.Errorf("bluetooth unavailable: %w (is Bluetooth on, and allowed for this terminal?)", err)
		}
	})
	return b.err
}

// Scan lists boards advertising the cli service for d.
func (b *BLE) Scan(ctx context.Context, d time.Duration) ([]Found, error) {
	if err := b.enable(); err != nil {
		return nil, err
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	type seen struct {
		f   Found
		cli bool
	}
	var mu sync.Mutex
	all := map[string]*seen{}
	ctx, cancel := context.WithTimeout(ctx, d)
	defer cancel()
	go func() {
		<-ctx.Done()
		b.adapter.StopScan()
	}()
	err := b.adapter.Scan(func(_ *bluetooth.Adapter, r bluetooth.ScanResult) {
		mu.Lock()
		defer mu.Unlock()
		k := r.Address.String()
		s := all[k]
		if s == nil {
			s = &seen{f: Found{Addr: k, ref: r.Address}}
			all[k] = s
		}
		if n := r.LocalName(); n != "" { // the name often comes in the scan response, a separate report
			s.f.Name = n
		}
		s.f.RSSI = r.RSSI
		s.cli = s.cli || r.HasServiceUUID(svcUUID)
	})
	if err != nil && ctx.Err() == nil {
		return nil, err
	}
	mu.Lock()
	defer mu.Unlock()
	var out []Found
	for _, s := range all {
		if s.cli {
			if s.f.Name == "" {
				s.f.Name = "ESP32 Agent"
			}
			out = append(out, s.f)
		}
	}
	return out, nil
}

// Connect opens a link: subscribe to cli_out, write frames to cli_in (write requests; the OS does long writes).
func (b *BLE) Connect(ctx context.Context, f Found) (proto.Link, error) {
	if err := b.enable(); err != nil {
		return nil, err
	}
	addr, ok := f.ref.(bluetooth.Address)
	if !ok {
		return nil, errors.New("board not found: scan again")
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	dev, err := b.adapter.Connect(addr, bluetooth.ConnectionParams{ConnectionTimeout: bluetooth.NewDuration(10 * time.Second)})
	if err != nil {
		return nil, fmt.Errorf("connect to %s: %w", f.Name, err)
	}
	fail := func(err error) (proto.Link, error) {
		dev.Disconnect()
		return nil, fmt.Errorf("connect to %s: %w", f.Name, err)
	}
	svcs, err := dev.DiscoverServices([]bluetooth.UUID{svcUUID})
	if err != nil || len(svcs) == 0 {
		return fail(fmt.Errorf("no cli service (firmware too old?): %v", err))
	}
	chars, err := svcs[0].DiscoverCharacteristics(nil) // all: cli_in_nr is optional
	if err != nil {
		return fail(fmt.Errorf("cli characteristics missing: %v", err))
	}
	var in, out, inNR *bluetooth.DeviceCharacteristic
	for i := range chars {
		switch chars[i].UUID() {
		case inUUID:
			in = &chars[i]
		case outUUID:
			out = &chars[i]
		case inNRUUID:
			inNR = &chars[i]
		}
	}
	if in == nil || out == nil {
		return fail(errors.New("cli characteristics missing"))
	}
	// Frames that fit one packet go as write commands: a write request waits for its response, and behind the
	// board's video that took seconds (CoreBluetooth gives up after 10 s, 2026-11-06). Longer ones (the OS splits
	// them into a long write) still need requests. One write at a time keeps the frames in counter order.
	var wmu sync.Mutex
	l := newChanLink(func(p []byte) error {
		wmu.Lock()
		defer wmu.Unlock()
		if inNR != nil {
			if room, err := inNR.GetMTU(); err == nil && len(p) <= int(room) {
				_, err := inNR.WriteWithoutResponse(p)
				return err
			}
		}
		_, err := in.Write(p)
		return err
	}, func() {
		b.links.Delete(addr.String())
		dev.Disconnect()
	})
	b.links.Store(addr.String(), l)
	if err := out.EnableNotifications(func(buf []byte) { l.deliver(append([]byte{}, buf...)) }); err != nil {
		l.Close()
		return nil, fmt.Errorf("subscribe to %s: %w", f.Name, err)
	}
	return l, nil
}
