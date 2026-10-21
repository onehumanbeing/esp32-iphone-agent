package app

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/daemon"
	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/upgrade"
)

// executable is the binary to replace (tests point it at a temp file).
var executable = func() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(exe)
}

func (a *App) upgrade(args []string) int {
	fs := newFS(new(string))
	check := fs.Bool("check", false, "only report whether a newer version exists")
	force := fs.Bool("force", false, "install the latest even if it is not newer (or this is a dev build)")
	if _, err := parse(fs, args); err != nil {
		return a.fail(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	idx, err := upgrade.Fetch(ctx, upgrade.URL())
	if err != nil {
		return a.fail(fmt.Errorf("could not read the version list: %w", err))
	}
	dev := !upgrade.Valid(Version)
	newer := !dev && upgrade.Compare(idx.Latest, Version) > 0
	if *check {
		out := map[string]any{"current": Version, "latest": idx.Latest, "update_available": newer}
		if dev {
			out["note"] = "development build: esp32agent upgrade --force installs " + idx.Latest
		}
		return a.print(daemon.Response{Status: "ok", Data: out})
	}
	if !newer && !*force {
		if dev {
			return a.fail(fmt.Errorf("this is a development build (%s); esp32agent upgrade --force installs %s", Version, idx.Latest))
		}
		return a.print(daemon.Response{Status: "ok", Data: map[string]any{"current": Version, "latest": idx.Latest,
			"message": "already up to date"}})
	}
	rel, ok := idx.Find(idx.Latest)
	if !ok {
		return a.fail(fmt.Errorf("version %s is not in the version list", idx.Latest))
	}
	asset, ok := rel.Assets[upgrade.Platform()]
	if !ok {
		return a.fail(fmt.Errorf("version %s has no build for %s", idx.Latest, upgrade.Platform()))
	}
	exe, err := executable()
	if err != nil {
		return a.fail(err)
	}
	if err := upgrade.Install(ctx, asset, exe); err != nil {
		if errors.Is(err, os.ErrPermission) {
			err = fmt.Errorf("%w (install the new version with the same rights as the old one)", err)
		}
		return a.fail(err)
	}
	stopped := a.Client != nil && a.Client.StopRunning() // the next command starts the new daemon
	return a.print(daemon.Response{Status: "ok", Data: map[string]any{"previous": Version, "version": idx.Latest,
		"path": exe, "daemon_stopped": stopped}})
}
