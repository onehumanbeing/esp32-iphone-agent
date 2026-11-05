// Package upgrade replaces the running binary with a newer release listed in versions.json.
package upgrade

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
)

// DefaultURL lists the releases; ESP32AGENT_VERSIONS_URL overrides it.
const DefaultURL = "https://handsy.tech/cli/versions.json"

const maxDownload = 200 << 20

type Asset struct {
	URL    string `json:"url"`
	SHA256 string `json:"sha256"`
}

type Release struct {
	Version string           `json:"version"`
	Date    string           `json:"date,omitempty"`
	Assets  map[string]Asset `json:"assets"`
}

// Index is versions.json.
type Index struct {
	Latest   string    `json:"latest"`
	Versions []Release `json:"versions"`
}

func URL() string {
	if u := os.Getenv("ESP32AGENT_VERSIONS_URL"); u != "" {
		return u
	}
	return DefaultURL
}

// Platform is the asset key, e.g. darwin_arm64.
func Platform() string { return runtime.GOOS + "_" + runtime.GOARCH }

func get(ctx context.Context, url string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		return nil, fmt.Errorf("%s: HTTP %d", url, resp.StatusCode)
	}
	return resp, nil
}

func Fetch(ctx context.Context, url string) (*Index, error) {
	resp, err := get(ctx, url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var idx Index
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&idx); err != nil {
		return nil, fmt.Errorf("versions.json: %w", err)
	}
	if _, ok := parse(idx.Latest); !ok {
		return nil, fmt.Errorf("versions.json: bad latest version %q", idx.Latest)
	}
	return &idx, nil
}

// Find is the release of version v.
func (idx *Index) Find(v string) (Release, bool) {
	for _, r := range idx.Versions {
		if r.Version == v {
			return r, true
		}
	}
	return Release{}, false
}

type semver struct {
	n   [3]int
	pre string
}

func parse(v string) (semver, bool) {
	v = strings.TrimPrefix(v, "v")
	core, pre, _ := strings.Cut(v, "-")
	parts := strings.Split(core, ".")
	if len(parts) != 3 {
		return semver{}, false
	}
	var s semver
	for i, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil || n < 0 {
			return semver{}, false
		}
		s.n[i] = n
	}
	s.pre = pre
	return s, true
}

// Valid: v is a semantic version (not a dev build).
func Valid(v string) bool { _, ok := parse(v); return ok }

// Compare is -1, 0 or 1 as a < b, a == b, a > b; a pre-release sorts before its release.
func Compare(a, b string) int {
	x, _ := parse(a)
	y, _ := parse(b)
	for i := range x.n {
		if x.n[i] != y.n[i] {
			if x.n[i] < y.n[i] {
				return -1
			}
			return 1
		}
	}
	switch {
	case x.pre == y.pre:
		return 0
	case x.pre == "":
		return 1
	case y.pre == "":
		return -1
	case x.pre < y.pre:
		return -1
	}
	return 1
}

// Install downloads the asset next to exe, checks its SHA-256, takes the binary out of the archive and moves it
// over exe (on Windows the running exe is renamed to .old first).
func Install(ctx context.Context, a Asset, exe string) error {
	if len(a.SHA256) != 64 {
		return errors.New("versions.json has no sha256 for this download")
	}
	dir := filepath.Dir(exe)
	resp, err := get(ctx, a.URL)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	arch, err := os.CreateTemp(dir, ".esp32agent-download-")
	if err != nil {
		return err
	}
	defer os.Remove(arch.Name())
	defer arch.Close()
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(arch, h), io.LimitReader(resp.Body, maxDownload+1))
	if err != nil {
		return err
	}
	if n > maxDownload {
		return errors.New("download too large")
	}
	if got := hex.EncodeToString(h.Sum(nil)); !strings.EqualFold(got, a.SHA256) {
		return fmt.Errorf("checksum mismatch (expected %s, got %s): not installed", a.SHA256, got)
	}
	bin, err := os.CreateTemp(dir, ".esp32agent-new-")
	if err != nil {
		return err
	}
	defer os.Remove(bin.Name())
	if err := extract(arch, n, strings.HasSuffix(strings.ToLower(a.URL), ".zip"), bin); err != nil {
		bin.Close()
		return err
	}
	if err := bin.Close(); err != nil {
		return err
	}
	if err := os.Chmod(bin.Name(), 0o755); err != nil {
		return err
	}
	if runtime.GOOS == "windows" {
		old := exe + ".old"
		os.Remove(old)
		if err := os.Rename(exe, old); err != nil {
			return err
		}
		if err := os.Rename(bin.Name(), exe); err != nil {
			os.Rename(old, exe)
			return err
		}
		return nil
	}
	return os.Rename(bin.Name(), exe)
}

func isBinary(name string) bool {
	base := filepath.Base(name)
	return base == "esp32agent" || base == "esp32agent.exe"
}

// extract copies the esp32agent binary out of a .tar.gz or .zip.
func extract(f *os.File, size int64, isZip bool, out io.Writer) error {
	if isZip {
		zr, err := zip.NewReader(f, size)
		if err != nil {
			return err
		}
		for _, zf := range zr.File {
			if isBinary(zf.Name) {
				r, err := zf.Open()
				if err != nil {
					return err
				}
				defer r.Close()
				_, err = io.Copy(out, io.LimitReader(r, maxDownload))
				return err
			}
		}
		return errors.New("no esp32agent binary in the archive")
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return err
	}
	gz, err := gzip.NewReader(f)
	if err != nil {
		return err
	}
	tr := tar.NewReader(gz)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			return errors.New("no esp32agent binary in the archive")
		}
		if err != nil {
			return err
		}
		if hdr.Typeflag == tar.TypeReg && isBinary(hdr.Name) {
			_, err = io.Copy(out, io.LimitReader(tr, maxDownload))
			return err
		}
	}
}
