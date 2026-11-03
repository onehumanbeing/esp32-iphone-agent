package daemon

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// Debug (ESP32AGENT_DEBUG=1) logs every request's command and outcome to daemon.log.
var Debug = os.Getenv("ESP32AGENT_DEBUG") == "1"

// boardLog reads the board's RAM log a page at a time (firmware 0.2.3+: "logs <offset> <max>") and its last
// reset and crash. Older firmware answers neither; that is reported, not an error.
func (s *Server) boardLog(ctx context.Context, c *Conn) Response {
	crash, _ := c.Send(ctx, "crash")
	var b strings.Builder
	from := 0
	for page := 0; page < 200; page++ {
		reply, err := c.Send(ctx, fmt.Sprintf("logs %d 200", from))
		if err != nil {
			if page == 0 {
				return ok(map[string]string{"crash": crash, "log": "", "note": "this firmware keeps no log (needs 0.2.3 or later)"})
			}
			return fail(err)
		}
		next, end, text, perr := parseLogPage(reply)
		if perr != nil {
			return fail(perr)
		}
		b.WriteString(text)
		if next >= end || next == from {
			break
		}
		from = next
	}
	return ok(map[string]string{"crash": crash, "log": b.String()})
}

// parseLogPage reads "<next> <end> <text>", the text with '\n' and '\\' escaped by the board.
func parseLogPage(reply string) (next, end int, text string, err error) {
	parts := strings.SplitN(reply, " ", 3)
	if len(parts) < 2 {
		return 0, 0, "", fmt.Errorf("bad log page %q", reply)
	}
	if next, err = strconv.Atoi(parts[0]); err == nil {
		end, err = strconv.Atoi(parts[1])
	}
	if err != nil {
		return 0, 0, "", fmt.Errorf("bad log page %q", reply)
	}
	if len(parts) == 3 {
		var b strings.Builder
		escaped := false
		for _, r := range parts[2] {
			switch {
			case escaped && r == 'n':
				b.WriteByte('\n')
				escaped = false
			case escaped:
				b.WriteRune(r)
				escaped = false
			case r == '\\':
				escaped = true
			default:
				b.WriteRune(r)
			}
		}
		text = b.String()
	}
	return next, end, text, nil
}

// rotateLog keeps daemon.log under max bytes: daemon.log -> daemon.1.log -> ... -> daemon.<keep>.log.
func rotateLog(path string, max int64, keep int) {
	if st, err := os.Stat(path); err != nil || st.Size() < max {
		return
	}
	base := strings.TrimSuffix(path, ".log")
	os.Remove(fmt.Sprintf("%s.%d.log", base, keep))
	for i := keep - 1; i >= 1; i-- {
		os.Rename(fmt.Sprintf("%s.%d.log", base, i), fmt.Sprintf("%s.%d.log", base, i+1))
	}
	os.Rename(path, base+".1.log")
}
