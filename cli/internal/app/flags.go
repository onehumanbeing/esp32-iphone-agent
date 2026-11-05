package app

import (
	"flag"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// parse parses flags anywhere among the arguments (`io tap 10,20 --device X`), returning the positionals.
func parse(fs *flag.FlagSet, args []string) ([]string, error) {
	fs.SetOutput(io.Discard)
	var flags, pos []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			pos = append(pos, args[i+1:]...)
			break
		}
		if len(a) < 2 || a[0] != '-' || isNumber(a) {
			pos = append(pos, a)
			continue
		}
		flags = append(flags, a)
		name := strings.TrimLeft(a, "-")
		if strings.Contains(name, "=") {
			continue
		}
		if f := fs.Lookup(name); f != nil && !isBool(f) && i+1 < len(args) {
			i++
			flags = append(flags, args[i])
		}
	}
	return pos, fs.Parse(flags)
}

func isBool(f *flag.Flag) bool {
	b, ok := f.Value.(interface{ IsBoolFlag() bool })
	return ok && b.IsBoolFlag()
}

// isNumber lets negative coordinates through as positionals ("-5,10").
func isNumber(s string) bool {
	_, err := strconv.ParseFloat(strings.Split(s, ",")[0], 64)
	return err == nil
}

// coords parses "X,Y[,X2,Y2]".
func coords(s string, n int) ([]float64, error) {
	parts := strings.Split(s, ",")
	if len(parts) != n {
		return nil, fmt.Errorf("expected %d comma-separated numbers, got %q", n, s)
	}
	out := make([]float64, n)
	for i, p := range parts {
		v, err := strconv.ParseFloat(strings.TrimSpace(p), 64)
		if err != nil {
			return nil, fmt.Errorf("bad coordinate %q", p)
		}
		out[i] = v
	}
	return out, nil
}
