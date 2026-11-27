package ble

import (
	"testing"

	"tinygo.org/x/bluetooth"
)

func TestConnectedRejectsZeroDevice(t *testing.T) {
	if connected(bluetooth.Device{}) { // what darwin's Connect returns for a failed connect, with a nil error
		t.Fatal("a zero Device must not count as connected")
	}
}

func TestBoardsKeepsAppOnlyIdentity(t *testing.T) {
	all := map[string]*seen{
		"a": {f: Found{Name: "CLI ESP32 Agent E029", Addr: "a"}, cli: true},
		"b": {f: Found{Name: "ESP32 Agent E029", Addr: "b"}, app: true}, // same board, its app identity: dropped
		"c": {f: Found{Name: "ESP32 Agent 6AD5", Addr: "c"}, app: true}, // only the app identity: kept, AppOnly
		"d": {f: Found{Name: "Keyboard", Addr: "d"}},                    // not a board
	}
	got := map[string]Found{}
	for _, f := range boards(all) {
		got[f.Addr] = f
	}
	if len(got) != 2 || got["a"].AppOnly || !got["c"].AppOnly {
		t.Fatalf("boards = %+v", got)
	}
}
