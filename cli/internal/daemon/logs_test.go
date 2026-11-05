package daemon

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseLogPage(t *testing.T) {
	next, end, text, err := parseLogPage(`12 40 a\nC:\\b`)
	if err != nil || next != 12 || end != 40 || text != "a\nC:\\b" {
		t.Fatalf("got %d %d %q %v", next, end, text, err)
	}
	if _, _, text, err := parseLogPage("40 40"); err != nil || text != "" {
		t.Fatalf("empty page: %q %v", text, err)
	}
	if _, _, _, err := parseLogPage("rst usb"); err == nil {
		t.Fatal("not a page")
	}
}

func TestRotateLog(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "daemon.log")
	for i := 0; i < 5; i++ {
		os.WriteFile(path, make([]byte, 10+i), 0o600)
		rotateLog(path, 10, 3)
	}
	for i, want := range map[int]int64{1: 14, 2: 13, 3: 12} {
		st, err := os.Stat(filepath.Join(dir, "daemon."+string(rune('0'+i))+".log"))
		if err != nil || st.Size() != want {
			t.Fatalf("daemon.%d.log: %v", i, err)
		}
	}
	if _, err := os.Stat(filepath.Join(dir, "daemon.4.log")); err == nil {
		t.Fatal("kept more than 3")
	}
	if _, err := os.Stat(path); err == nil {
		t.Fatal("the full log was not moved")
	}
}
