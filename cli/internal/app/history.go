package app

import (
	"errors"
	"strconv"
	"strings"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/daemon"
	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/history"
)

func (a *App) runs() string { return history.Root(a.Dir) }

func (a *App) history(args []string) int {
	sub := ""
	if len(args) > 0 {
		sub = args[0]
	}
	switch sub {
	case "", "list":
		list, err := history.List(a.runs(), 30)
		if err != nil {
			return a.fail(err)
		}
		return a.print(daemon.Response{Status: "ok", Data: map[string]any{"runs": list}})
	case "show":
		id := ""
		if len(args) > 1 {
			id = args[1]
		}
		run, err := history.Load(a.runs(), id)
		if err != nil {
			return a.fail(err)
		}
		return a.print(daemon.Response{Status: "ok", Data: run})
	case "new":
		id, err := (&history.Recorder{Dir: a.runs()}).New(strings.Join(args[1:], " "))
		if err != nil {
			return a.fail(err)
		}
		return a.print(daemon.Response{Status: "ok", Data: map[string]string{"id": id, "message": "new run started"}})
	}
	return a.fail(errors.New("usage: esp32agent history list | show RUN | new"))
}

// ints parses "1,3,4".
func ints(s string) ([]int, error) {
	var out []int
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p == "" {
			continue
		}
		n, err := strconv.Atoi(p)
		if err != nil {
			return nil, errors.New("--steps takes step numbers like 1,3,4")
		}
		out = append(out, n)
	}
	return out, nil
}
