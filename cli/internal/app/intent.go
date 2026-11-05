package app

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/daemon"
	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/intent"
)

type multi []string

func (m *multi) String() string     { return strings.Join(*m, ", ") }
func (m *multi) Set(s string) error { *m = append(*m, s); return nil }

func (a *App) intents() intent.Store { return intent.Store{Dir: a.Dir} }

// summary is an intent in `intent list`.
func summary(it intent.Intent) map[string]any {
	return map[string]any{"id": it.ID, "name": it.Name, "prompt": it.Prompt, "hints": len(it.Hints), "steps": len(it.Steps)}
}

// shown is an intent with its steps' screen files, for `intent show`.
func (a *App) shown(it intent.Intent) map[string]any {
	steps := []map[string]any{}
	for i, st := range it.Steps {
		s := map[string]any{"step": i + 1, "action": st.Action, "sure": st.Sure}
		if p := a.intents().FramePath(it.ID, st); p != "" {
			s["frame"] = p
		}
		steps = append(steps, s)
	}
	out := map[string]any{"id": it.ID, "name": it.Name, "prompt": it.Prompt, "hints": it.Hints, "steps": steps}
	if it.RefRun != "" {
		out["from_run"] = it.RefRun
	}
	return out
}

func (a *App) find(key string) (intent.Intent, error) {
	items, err := a.intents().Load()
	if err != nil {
		return intent.Intent{}, err
	}
	i, err := intent.Find(items, key)
	if err != nil {
		return intent.Intent{}, err
	}
	return items[i], nil
}

func (a *App) intent(args []string) int {
	fs := newFS(new(string))
	name := fs.String("name", "", "intent name")
	prompt := fs.String("prompt", "", "the instruction")
	var hints multi
	fs.Var(&hints, "hint", "a hint (repeat, at most 6)")
	fromRun := fs.String("from-run", "", "run id (history list) to take the steps from")
	steps := fs.String("steps", "", "step numbers of that run, e.g. 1,3,4 (default: every replayable one)")
	shots := fs.Bool("screenshots", false, "include the reference screens")
	output := fs.String("output", "", "file to write")
	pos, err := parse(fs, args)
	if err != nil {
		return a.fail(err)
	}
	if len(pos) == 0 {
		pos = []string{"list"}
	}
	sub, rest := pos[0], pos[1:]
	key := strings.Join(rest, " ")
	switch sub {
	case "list":
		items, err := a.intents().Load()
		if err != nil {
			return a.fail(err)
		}
		list := []map[string]any{}
		for _, it := range items {
			list = append(list, summary(it))
		}
		return a.print(daemon.Response{Status: "ok", Data: map[string]any{"intents": list}})
	case "show":
		it, err := a.find(key)
		if err != nil {
			return a.fail(err)
		}
		return a.print(daemon.Response{Status: "ok", Data: a.shown(it)})
	case "save":
		nums, err := ints(*steps)
		if err != nil {
			return a.fail(err)
		}
		it, err := a.intents().Save(intent.SaveOpts{Name: *name, Prompt: *prompt, Hints: hints, FromRun: *fromRun, Steps: nums})
		if err != nil {
			return a.fail(err)
		}
		return a.print(daemon.Response{Status: "ok", Data: a.shown(it)})
	case "delete":
		it, err := a.intents().Delete(key)
		if err != nil {
			return a.fail(err)
		}
		return a.print(daemon.Response{Status: "ok", Data: map[string]string{"id": it.ID, "message": "deleted " + it.Name}})
	case "export":
		return a.export(rest, *shots, *output)
	case "import":
		if len(rest) != 1 {
			return a.fail(errors.New("usage: esp32agent intent import FILE"))
		}
		data, err := os.ReadFile(rest[0])
		if err != nil {
			return a.fail(err)
		}
		items, err := intent.Decode(data)
		if err != nil {
			return a.fail(err)
		}
		added, skipped, err := a.intents().Import(items)
		if err != nil {
			return a.fail(err)
		}
		names := []string{}
		for _, it := range added {
			names = append(names, it.Name)
		}
		return a.print(daemon.Response{Status: "ok", Data: map[string]any{"added": names, "skipped": skipped}})
	}
	return a.fail(errors.New("usage: esp32agent intent list | show | save | delete | export | import"))
}

// export writes the intents named (each argument a name or id) as one .esp32intent file.
func (a *App) export(keys []string, screenshots bool, output string) int {
	if len(keys) == 0 {
		return a.fail(errors.New("usage: esp32agent intent export NAME|ID... [--screenshots] [--output FILE]"))
	}
	var items []intent.Item
	for _, k := range keys {
		it, err := a.find(k)
		if err != nil {
			return a.fail(err)
		}
		items = append(items, a.intents().Item(it, screenshots))
	}
	if output == "" {
		output = fileName(items)
	}
	path, err := writeArchive(output, items, "")
	if err != nil {
		return a.fail(err)
	}
	return a.print(daemon.Response{Status: "ok", Data: map[string]any{"filePath": path, "intents": len(items), "screenshots": screenshots}})
}

// fileName is the app's: the intent's name (or "Intents" for several), unsafe characters dropped.
func fileName(items []intent.Item) string {
	base := "Intents"
	if len(items) == 1 {
		base = items[0].Name
	}
	base = strings.TrimSpace(strings.Map(func(r rune) rune {
		if strings.ContainsRune(`/\:?*"<>|`, r) {
			return ' '
		}
		return r
	}, base))
	if base == "" {
		base = "Intent"
	}
	return base + "." + intent.Extension
}

func writeArchive(path string, items []intent.Item, note string) (string, error) {
	data, err := intent.Encode(items, note)
	if err != nil {
		return "", err
	}
	if len(data) > intent.MaxBytes {
		return "", fmt.Errorf("the file would be %d MB, over the %d MB the app takes", len(data)>>20, intent.MaxBytes/1_000_000)
	}
	if path, err = filepath.Abs(path); err != nil {
		return "", err
	}
	return path, os.WriteFile(path, data, 0o600)
}
