package app

import (
	"errors"
	"os"
	"path/filepath"
	"strings"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/daemon"
	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/memory"
)

func (a *App) memories() memory.Store { return memory.Store{Dir: filepath.Join(a.Dir, "memory")} }

// memory: the app's MEMORY.md on this computer (Settings › Memory exports and imports the same file).
func (a *App) memory(args []string) int {
	fs := newFS(new(string))
	kind := fs.String("kind", "fact", "preference | fact | app")
	topic := fs.String("topic", "", "app or subject, e.g. wechat")
	limit := fs.Int("limit", 5, "search: at most this many")
	output := fs.String("output", "MEMORY.md", "export: file to write")
	pos, err := parse(fs, args)
	if err != nil {
		return a.fail(err)
	}
	if len(pos) == 0 {
		pos = []string{"list"}
	}
	sub, text := pos[0], strings.Join(pos[1:], " ")
	store := a.memories()
	ok := func(v any) int { return a.print(daemon.Response{Status: "ok", Data: v}) }
	switch sub {
	case "list":
		es, err := store.Load()
		if err != nil {
			return a.fail(err)
		}
		return ok(map[string]any{"memories": es, "file": store.Path()})
	case "add":
		e, err := store.Add(text, *kind, *topic)
		if err != nil {
			return a.fail(err)
		}
		return ok(e)
	case "rm", "remove", "delete":
		e, err := store.Remove(text)
		if err != nil {
			return a.fail(err)
		}
		return ok(map[string]string{"id": e.ID, "message": "forgot: " + e.Text})
	case "search", "recall":
		es, err := store.Load()
		if err != nil {
			return a.fail(err)
		}
		return ok(map[string]any{"memories": memory.Recall(es, text, *limit)})
	case "export":
		es, err := store.Load()
		if err != nil {
			return a.fail(err)
		}
		path, err := filepath.Abs(*output)
		if err == nil {
			err = os.WriteFile(path, []byte(memory.Render(es)), 0o600)
		}
		if err != nil {
			return a.fail(err)
		}
		return ok(map[string]any{"filePath": path, "memories": len(es)})
	case "import":
		if len(pos) != 2 {
			return a.fail(errors.New("usage: esp32agent memory import FILE"))
		}
		data, err := os.ReadFile(pos[1])
		if err != nil {
			return a.fail(err)
		}
		added, updated, err := store.Import(string(data))
		if err != nil {
			return a.fail(err)
		}
		return ok(map[string]int{"added": added, "updated": updated})
	}
	return a.fail(errors.New("usage: esp32agent memory list | add TEXT | rm ID | search TEXT | export | import FILE"))
}
