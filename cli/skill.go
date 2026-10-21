// Package cli holds files embedded in the esp32agent binary.
package cli

import _ "embed"

// Skill is SKILL.md, installed for agents by `esp32agent skill install`.
//
//go:embed SKILL.md
var Skill string
