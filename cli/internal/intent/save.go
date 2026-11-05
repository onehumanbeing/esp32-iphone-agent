package intent

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/history"
)

// MaxHints is the optimizer's limit (ReviewModel.optimizerPrompt).
const MaxHints = 6

// SaveOpts is `intent save`: Steps are run step numbers (history show); none means every replayable one.
type SaveOpts struct {
	Name, Prompt string
	Hints        []string
	FromRun      string
	Steps        []int
}

// Save adds the intent at the top, or replaces the one with the same name (keeping its id).
func (s Store) Save(o SaveOpts) (Intent, error) {
	o.Name, o.Prompt = strings.TrimSpace(o.Name), strings.TrimSpace(o.Prompt)
	if o.Name == "" || o.Prompt == "" {
		return Intent{}, errors.New("intent save needs --name and --prompt")
	}
	var hints []string
	for _, h := range o.Hints {
		if h = strings.TrimSpace(h); h != "" {
			hints = append(hints, h)
		}
	}
	if len(hints) > MaxHints {
		return Intent{}, fmt.Errorf("at most %d hints", MaxHints)
	}
	if len(o.Steps) > 0 && o.FromRun == "" {
		return Intent{}, errors.New("--steps needs --from-run")
	}
	items, err := s.Load()
	if err != nil {
		return Intent{}, err
	}
	it := Intent{ID: NewID(), Name: o.Name, Prompt: o.Prompt, Hints: hints}
	old := -1
	for i, x := range items {
		if strings.EqualFold(x.Name, o.Name) {
			old, it.ID, it.Icon, it.History = i, x.ID, x.Icon, x.History
			break
		}
	}
	if o.FromRun != "" {
		run, err := history.Load(history.Root(s.Dir), o.FromRun)
		if err != nil {
			return Intent{}, err
		}
		picked, err := pick(run, o.Steps)
		if err != nil {
			return Intent{}, err
		}
		os.RemoveAll(s.Frames(it.ID))
		if it.Steps, err = s.copySteps(it.ID, run, picked); err != nil {
			return Intent{}, err
		}
		it.RefRun = run.ID
	} else if old >= 0 {
		it.Steps, it.RefRun = items[old].Steps, items[old].RefRun
	}
	if old >= 0 {
		items = append(items[:old:old], items[old+1:]...)
	}
	return it, s.Put(append([]Intent{it}, items...))
}

func pick(run *history.Run, nums []int) ([]history.Step, error) {
	var out []history.Step
	if len(nums) == 0 {
		for _, st := range run.Steps {
			if st.Replayable() {
				out = append(out, st)
			}
		}
		if len(out) == 0 {
			return nil, fmt.Errorf("run %s has no replayable steps (tap, swipe, type, key, home)", run.ID)
		}
		return out, nil
	}
	for _, n := range nums {
		if n < 1 || n > len(run.Steps) {
			return nil, fmt.Errorf("run %s has no step %d (it has %d)", run.ID, n, len(run.Steps))
		}
		st := run.Steps[n-1]
		if !st.Replayable() {
			return nil, fmt.Errorf("step %d (%s) is not a replayable move that worked", n, st.JSON())
		}
		out = append(out, st)
	}
	return out, nil
}

// copySteps makes recorded steps (sure) with their screens as sNN.jpg.
func (s Store) copySteps(id string, run *history.Run, steps []history.Step) ([]Step, error) {
	out := []Step{}
	for i, st := range steps {
		rs := Step{Action: st.JSON(), Sure: true}
		if st.Frame != "" {
			if data, err := os.ReadFile(filepath.Join(run.Dir, filepath.Base(st.Frame))); err == nil {
				if err := s.writeFrame(id, i, data, &rs); err != nil {
					return nil, err
				}
			}
		}
		out = append(out, rs)
	}
	return out, nil
}

func (s Store) writeFrame(id string, i int, data []byte, st *Step) error {
	if err := os.MkdirAll(s.Frames(id), 0o700); err != nil {
		return err
	}
	name := fmt.Sprintf("s%02d.jpg", i+1)
	if err := os.WriteFile(filepath.Join(s.Frames(id), name), data, 0o600); err != nil {
		return err
	}
	st.Frame = str(name)
	return nil
}
