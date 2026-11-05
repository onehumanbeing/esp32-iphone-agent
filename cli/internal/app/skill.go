package app

import (
	"os"
	"path/filepath"

	cli "github.com/onehumanbeing/esp32-iphone-agent/cli"
	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/daemon"
)

// skillInstall writes the skill for Claude Code and says how to set up Codex.
func (a *App) skillInstall() int {
	home, err := os.UserHomeDir()
	if err != nil {
		return a.fail(err)
	}
	dir := filepath.Join(home, ".claude", "skills", "esp32agent")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return a.fail(err)
	}
	path := filepath.Join(dir, "SKILL.md")
	if err := os.WriteFile(path, []byte(cli.Skill), 0o644); err != nil {
		return a.fail(err)
	}
	return a.print(daemon.Response{Status: "ok", Data: map[string]any{
		"claude": map[string]string{"skill": path, "mcp": "claude mcp add esp32agent -- esp32agent mcp"},
		"codex": map[string]string{"mcp": "codex mcp add esp32agent -- esp32agent mcp",
			"skill": "copy " + path + " to ~/.codex/skills/esp32agent/SKILL.md, or paste it into AGENTS.md"},
	}})
}
