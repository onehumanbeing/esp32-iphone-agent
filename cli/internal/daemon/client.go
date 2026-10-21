package daemon

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

func SocketPath(dir string) string { return filepath.Join(dir, "daemon.sock") }
func LogPath(dir string) string    { return filepath.Join(dir, "daemon.log") }

// Client reaches the daemon, starting it when it is not running (or runs another version).
type Client struct {
	Dir     string
	Version string
	NoSpawn bool // tests: the daemon runs in process
}

func (c *Client) dial() (net.Conn, error) {
	return net.DialTimeout("unix", SocketPath(c.Dir), 2*time.Second)
}

func (c *Client) ensure() error {
	if conn, err := c.dial(); err == nil {
		conn.Close()
		if c.NoSpawn {
			return nil
		}
		var v struct {
			Data struct{ Version string } `json:"data"`
		}
		if r, err := c.roundTrip(Request{Cmd: "version"}); err == nil && json.Unmarshal(r, &v) == nil && v.Data.Version == c.Version {
			return nil
		}
		c.roundTrip(Request{Cmd: "stop"}) // left over from another version
		time.Sleep(300 * time.Millisecond)
	} else if c.NoSpawn {
		return err
	}
	return c.spawn()
}

func (c *Client) spawn() error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	logf, err := os.OpenFile(LogPath(c.Dir), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer logf.Close()
	cmd := exec.Command(exe, "daemon")
	cmd.Stdout, cmd.Stderr = logf, logf
	detach(cmd)
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start daemon: %w", err)
	}
	go cmd.Wait()
	for i := 0; i < 50; i++ {
		time.Sleep(100 * time.Millisecond)
		if conn, err := c.dial(); err == nil {
			conn.Close()
			return nil
		}
	}
	return fmt.Errorf("daemon did not start; see %s", LogPath(c.Dir))
}

func (c *Client) roundTrip(req Request) ([]byte, error) {
	conn, err := c.dial()
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	if err := json.NewEncoder(conn).Encode(req); err != nil {
		return nil, err
	}
	line, err := bufio.NewReaderSize(conn, 1<<20).ReadBytes('\n')
	if err != nil && len(line) == 0 {
		return nil, errors.New("daemon closed the connection (see " + LogPath(c.Dir) + ")")
	}
	return line, nil
}

// Call runs one request and returns the daemon's JSON response line.
func (c *Client) Call(req Request) ([]byte, error) {
	if err := c.ensure(); err != nil {
		return nil, err
	}
	return c.roundTrip(req)
}

// Stream runs a streaming request: the header response, then raw bytes copied to w until either side stops.
func (c *Client) Stream(req Request, w io.Writer) ([]byte, error) {
	if err := c.ensure(); err != nil {
		return nil, err
	}
	conn, err := c.dial()
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	if err := json.NewEncoder(conn).Encode(req); err != nil {
		return nil, err
	}
	r := bufio.NewReader(conn)
	line, err := r.ReadBytes('\n')
	if err != nil {
		return nil, err
	}
	var hdr Response
	if json.Unmarshal(line, &hdr) != nil || hdr.Status != "ok" {
		return line, nil
	}
	_, err = io.Copy(w, r)
	return line, err
}
