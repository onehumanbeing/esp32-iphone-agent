package app

import (
	"encoding/json"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/history"
	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/intent"
)

// Tools answered here, from the files in the config dir, without the daemon or a board.

func local(required []string, props map[string]any) map[string]any {
	if required == nil {
		required = []string{}
	}
	return map[string]any{"type": "object", "properties": props, "required": required}
}

var (
	strProp    = map[string]any{"type": "string"}
	localTools = []tool{
		{"history", "What was done on the phone: action list (the newest runs) or show (one run's steps, in 0-1000 screen units, each with the screenshot it was done on). A run ends after 10 minutes idle.",
			local([]string{"action"}, map[string]any{"action": map[string]any{"type": "string", "enum": []string{"list", "show"}},
				"run": map[string]any{"type": "string", "description": "run id from list; default the newest"}})},
		{"intent_list", "Saved intents: id, name, prompt, number of hints and steps.", local(nil, map[string]any{})},
		{"intent_show", "One saved intent: prompt, hints and its recorded steps (0-1000 screen units) with their reference screens.",
			local([]string{"name"}, map[string]any{"name": map[string]any{"type": "string", "description": "name or id"}})},
		{"intent_save", "Save what worked as an intent: a short prompt, up to 6 hints, and the replayable steps of a run (from history). Same name replaces.",
			local([]string{"name", "prompt"}, map[string]any{"name": strProp, "prompt": strProp,
				"hints":    map[string]any{"type": "array", "items": strProp, "maxItems": intent.MaxHints},
				"from_run": map[string]any{"type": "string", "description": "run id; its replayable steps become the intent's"},
				"steps":    map[string]any{"type": "array", "items": map[string]any{"type": "integer"}, "description": "step numbers of that run (default: every replayable one)"}})},
	}
)

func jsonResult(v any, err error) map[string]any {
	if err != nil {
		return textResult(err.Error(), true)
	}
	b, _ := json.Marshal(v)
	return textResult(string(b), false)
}

// callLocal handles the local tools; ok=false for the others.
func (a *App) callLocal(name string, args map[string]any) (map[string]any, bool) {
	s := func(k string) string { v, _ := args[k].(string); return v }
	switch name {
	case "history":
		if s("action") == "show" {
			return jsonResult(history.Load(a.runs(), s("run"))), true
		}
		return jsonResult(history.List(a.runs(), 30)), true
	case "intent_list":
		items, err := a.intents().Load()
		list := []map[string]any{}
		for _, it := range items {
			list = append(list, summary(it))
		}
		return jsonResult(list, err), true
	case "intent_show":
		it, err := a.find(s("name"))
		if err != nil {
			return textResult(err.Error(), true), true
		}
		return jsonResult(a.shown(it), nil), true
	case "intent_save":
		o := intent.SaveOpts{Name: s("name"), Prompt: s("prompt"), FromRun: s("from_run")}
		hints, _ := args["hints"].([]any)
		for _, h := range hints {
			if t, ok := h.(string); ok {
				o.Hints = append(o.Hints, t)
			}
		}
		steps, _ := args["steps"].([]any)
		for _, n := range steps {
			if f, ok := n.(float64); ok {
				o.Steps = append(o.Steps, int(f))
			}
		}
		it, err := a.intents().Save(o)
		if err != nil {
			return textResult(err.Error(), true), true
		}
		return jsonResult(a.shown(it), nil), true
	}
	return nil, false
}
