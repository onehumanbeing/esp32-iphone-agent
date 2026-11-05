//go:build !windows

package daemon

import (
	"os/exec"
	"syscall"
)

// detach runs the daemon in its own session, so it outlives the terminal command that started it.
func detach(cmd *exec.Cmd) { cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true} }
