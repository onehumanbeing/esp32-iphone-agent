package app

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"

	"github.com/onehumanbeing/esp32-iphone-agent/cli/internal/daemon"
)

// A small MCP server (JSON-RPC 2.0, one message per line on stdio) with the CLI's commands as tools.

type rpcMsg struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type tool struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
}

func schema(required []string, props map[string]any) map[string]any {
	props["device"] = map[string]any{"type": "string", "description": "board id; only needed with several boards"}
	if required == nil {
		required = []string{}
	}
	return map[string]any{"type": "object", "properties": props, "required": required}
}

var (
	numProp = map[string]any{"type": "number"}
	tools   = []tool{
		{"screenshot", "The iPhone's screen now (after the last action has settled). Coordinates for the other tools are pixels of this image.", schema(nil, map[string]any{})},
		{"tap", "Tap at x, y (screenshot pixels).", schema([]string{"x", "y"}, map[string]any{"x": numProp, "y": numProp,
			"count": map[string]any{"type": "integer", "description": "taps in a row at the point; 2 is a double tap (default 1)"}})},
		{"longpress", "Press and hold at x, y.", schema([]string{"x", "y"}, map[string]any{"x": numProp, "y": numProp,
			"duration_ms": map[string]any{"type": "integer", "description": "default 1000"}})},
		{"swipe", "Swipe from x1, y1 to x2, y2 (rests at the end, so lists stop there).", schema([]string{"x1", "y1", "x2", "y2"},
			map[string]any{"x1": numProp, "y1": numProp, "x2": numProp, "y2": numProp})},
		{"type_text", "Type text into the focused field. ASCII only: Chinese is typed as pinyin (then commit a candidate with press_key space or a tap).",
			schema([]string{"text"}, map[string]any{"text": map[string]any{"type": "string"}})},
		{"press_key", "Press a key or combo: enter, esc, tab, backspace, space, up, down, left, right, cmd+a, shift+tab ...",
			schema([]string{"key"}, map[string]any{"key": map[string]any{"type": "string"}})},
		{"press_button", "Press a hardware button. Only HOME (go to the Home Screen).",
			schema([]string{"button"}, map[string]any{"button": map[string]any{"type": "string", "enum": []string{"HOME"}}})},
		{"device_info", "Board status: mirroring (ap), video frozen (fz), app busy (busy), USB, BLE link.", schema(nil, map[string]any{})},
	}
)

func (a *App) mcp(in io.Reader) int {
	r := bufio.NewReaderSize(in, 1<<20)
	enc := json.NewEncoder(a.Out)
	for {
		line, err := r.ReadBytes('\n')
		if len(line) > 0 {
			var m rpcMsg
			if json.Unmarshal(line, &m) != nil {
				enc.Encode(rpcMsg{JSONRPC: "2.0", ID: json.RawMessage("null"), Error: &rpcError{-32700, "parse error"}})
			} else if resp := a.handleRPC(m); resp != nil {
				enc.Encode(resp)
			}
		}
		if err != nil {
			return 0
		}
	}
}

func (a *App) handleRPC(m rpcMsg) *rpcMsg {
	if m.ID == nil { // a notification
		return nil
	}
	resp := &rpcMsg{JSONRPC: "2.0", ID: m.ID}
	switch m.Method {
	case "initialize":
		var p struct {
			ProtocolVersion string `json:"protocolVersion"`
		}
		json.Unmarshal(m.Params, &p)
		if p.ProtocolVersion == "" {
			p.ProtocolVersion = "2025-06-18"
		}
		resp.Result = raw(map[string]any{"protocolVersion": p.ProtocolVersion, "capabilities": map[string]any{"tools": map[string]any{}},
			"serverInfo":   map[string]string{"name": "esp32agent", "version": Version},
			"instructions": "Drives a real iPhone through an ESP32 Agent board. Loop: screenshot, decide, one action, screenshot again."})
	case "ping":
		resp.Result = raw(map[string]any{})
	case "tools/list":
		resp.Result = raw(map[string]any{"tools": append(append([]tool{}, tools...), localTools...)})
	case "tools/call":
		var p struct {
			Name      string         `json:"name"`
			Arguments map[string]any `json:"arguments"`
		}
		if err := json.Unmarshal(m.Params, &p); err != nil {
			resp.Error = &rpcError{-32602, err.Error()}
			break
		}
		resp.Result = raw(a.callTool(p.Name, p.Arguments))
	default:
		resp.Error = &rpcError{-32601, "method not found: " + m.Method}
	}
	return resp
}

func raw(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}

func textResult(s string, isErr bool) map[string]any {
	return map[string]any{"content": []map[string]any{{"type": "text", "text": s}}, "isError": isErr}
}

func (a *App) callTool(name string, args map[string]any) map[string]any {
	if r, ok := a.callLocal(name, args); ok {
		return r
	}
	f := func(k string) float64 { v, _ := args[k].(float64); return v }
	s := func(k string) string { v, _ := args[k].(string); return v }
	dev := s("device")
	if dev == "" {
		dev = os.Getenv("ESP32AGENT_DEVICE")
	}
	req := daemon.Request{Device: dev}
	switch name {
	case "screenshot":
		req.Cmd = "screenshot"
	case "tap", "longpress":
		req.Cmd, req.Pts, req.Ms, req.Count = name, []float64{f("x"), f("y")}, int(f("duration_ms")), int(f("count"))
	case "swipe":
		req.Cmd, req.Pts = "swipe", []float64{f("x1"), f("y1"), f("x2"), f("y2")}
	case "type_text":
		req.Cmd, req.Text = "text", s("text")
	case "press_key":
		req.Cmd, req.Text = "keys", s("key")
	case "press_button":
		req.Cmd, req.Text = "button", s("button")
	case "device_info":
		req.Cmd = "info"
	default:
		return textResult("unknown tool "+name, true)
	}
	line, err := a.Client.Call(req)
	if err != nil {
		return textResult(err.Error(), true)
	}
	var r struct {
		daemon.Response
		Raw json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(line, &r); err != nil {
		return textResult("bad response from the daemon", true)
	}
	if r.Status != "ok" {
		return textResult(r.Error, true)
	}
	if name == "screenshot" {
		var d struct {
			Format, Data  string
			Width, Height int
		}
		json.Unmarshal(r.Raw, &d)
		return map[string]any{"content": []map[string]any{
			{"type": "image", "data": d.Data, "mimeType": "image/" + d.Format},
			{"type": "text", "text": fmt.Sprintf("%dx%d screenshot; tap coordinates are pixels of this image", d.Width, d.Height)},
		}, "isError": false}
	}
	return textResult(string(r.Raw), false)
}
