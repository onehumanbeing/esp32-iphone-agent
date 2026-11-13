package memory

import (
	"os"
	"testing"
)

// The same file the iOS tests read (ios/IPhoneAgentTests/MemoryTests.swift).
func shared(t *testing.T) string {
	b, err := os.ReadFile("../../testdata/memory/MEMORY.md")
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestTheAppsFileRoundTripsUnchanged(t *testing.T) {
	text := shared(t)
	es := Parse(text)
	if len(es) != 4 || es[0].ID != "a1b2c3d4" || es[2].Topic != "wechat" || es[0].Kind != "preference" {
		t.Fatalf("parsed %+v", es)
	}
	if got := Render(es); got != text {
		t.Fatalf("render differs:\n%s", got)
	}
}

// Same queries and order as the app's testRecallMatchesTheCLI.
func TestRecallMatchesTheApp(t *testing.T) {
	es := Parse(shared(t))
	if r := Recall(es, "open bilibili favorites", 5); len(r) == 0 || r[0].ID != "a1b2c3d4" {
		t.Fatalf("bilibili: %+v", r)
	}
	if r := Recall(es, "给文件传输助手发 ok", 5); len(r) == 0 || r[0].ID != "c3d4e5f6" {
		t.Fatalf("wechat: %+v", r)
	}
}

func TestStoreAddImportRemove(t *testing.T) {
	s := Store{Dir: t.TempDir()}
	if a, u, err := s.Import(shared(t)); err != nil || a != 4 || u != 0 {
		t.Fatal(a, u, err)
	}
	if _, err := s.Add("The WeChat password is hunter2", "fact", ""); err == nil {
		t.Fatal("kept a password")
	}
	if _, err := s.Add("i prefer SHORT answers in chinese.", "preference", ""); err == nil {
		t.Fatal("kept a duplicate")
	}
	e, err := s.Add("Reports go to the Ops group", "app", "Lark App")
	if err != nil || e.Topic != "lark-app" || len(e.ID) != 8 {
		t.Fatal(e, err)
	}
	newer := "<!-- 2030-01-01 00:00:00 [a1b2c3d4] -->\n#preference [[bilibili]] Favorites moved.\n"
	if a, u, _ := s.Import(newer); a != 0 || u != 1 {
		t.Fatal(a, u)
	}
	es, _ := s.Load()
	if es[0].Text != "Favorites moved." || len(es) != 5 {
		t.Fatalf("%+v", es)
	}
	if a, u, _ := s.Import(Render(es)); a+u != 0 {
		t.Fatal("re-import changed something", a, u)
	}
	if _, err := s.Remove(e.ID); err != nil {
		t.Fatal(err)
	}
	if es, _ = s.Load(); len(es) != 4 {
		t.Fatal(len(es))
	}
}
