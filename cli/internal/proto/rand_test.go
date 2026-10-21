package proto

import (
	"go/parser"
	"go/token"
	"io/fs"
	"path/filepath"
	"strings"
	"testing"
)

// Every random value (X25519 keys, client_id, nonces) comes from crypto/rand: math/rand is banned in cli/.
func TestNoMathRand(t *testing.T) {
	filepath.WalkDir("../..", func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".go") {
			return err
		}
		f, err := parser.ParseFile(token.NewFileSet(), path, nil, parser.ImportsOnly)
		if err != nil {
			t.Fatal(err)
		}
		for _, imp := range f.Imports {
			if strings.HasPrefix(strings.Trim(imp.Path.Value, `"`), "math/rand") {
				t.Errorf("%s imports %s", path, imp.Path.Value)
			}
		}
		return nil
	})
}
