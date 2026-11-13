// Package memory is the iOS app's long-term memory (MEMORY.md) on the computer: the same file format, recall and
// sensitive-line filter as ios/IPhoneAgent/Services/MemoryStore.swift, so a file moves between them with
// `esp32agent memory export` / `import` and the app's Settings › Memory.
//
//	<!-- 2026-11-02 10:12:03 [a1b2c3d4] -->
//	#preference [[bilibili]] Favorites are under Me › Favorites.
package memory

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode"
)

// Kinds, as the app writes them.
var Kinds = []string{"preference", "fact", "app"}

// MaxChars is the longest line the app keeps.
const MaxChars = 300

const stamp = "2006-01-02 15:04:05"

// Entry is one remembered line.
type Entry struct {
	ID    string    `json:"id"`
	Date  time.Time `json:"date"`
	Kind  string    `json:"kind"`
	Topic string    `json:"topic,omitempty"`
	Text  string    `json:"text"`
}

var header = regexp.MustCompile(`<!-- (.+) \[([0-9a-z]+)\] -->`)

// Parse reads MEMORY.md; a line it does not know is skipped.
func Parse(text string) []Entry {
	var out []Entry
	var id string
	var date time.Time
	have := false
	for _, raw := range strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n") {
		line := strings.TrimSpace(raw)
		if strings.HasPrefix(line, "<!--") {
			if m := header.FindStringSubmatch(line); m != nil {
				d, err := time.ParseInLocation(stamp, strings.TrimSpace(m[1]), time.Local)
				if err != nil {
					d = time.Now()
				}
				id, date, have = m[2], d, true
				continue
			}
		}
		if !strings.HasPrefix(line, "#") || !have {
			continue
		}
		rest := line[1:]
		kind := rest
		if i := strings.IndexFunc(rest, unicode.IsSpace); i >= 0 {
			kind, rest = rest[:i], strings.TrimLeftFunc(rest[i:], unicode.IsSpace)
		} else {
			rest = ""
		}
		topic := ""
		if strings.HasPrefix(rest, "[[") {
			if end := strings.Index(rest, "]]"); end >= 0 {
				topic, rest = rest[2:end], strings.TrimLeftFunc(rest[end+2:], unicode.IsSpace)
			}
		}
		if !validKind(kind) {
			kind = "fact"
		}
		out = append(out, Entry{ID: id, Date: date, Kind: kind, Topic: topic, Text: rest})
		have = false
	}
	return out
}

// Render writes MEMORY.md exactly as the app does.
func Render(entries []Entry) string {
	parts := make([]string, len(entries))
	for i, e := range entries {
		t := ""
		if e.Topic != "" {
			t = "[[" + e.Topic + "]] "
		}
		parts[i] = "<!-- " + e.Date.In(time.Local).Format(stamp) + " [" + e.ID + "] -->\n#" + e.Kind + " " + t + e.Text
	}
	out := strings.Join(parts, "\n\n")
	if len(entries) > 0 {
		out += "\n"
	}
	return out
}

// Merged folds theirs into mine: an entry with the same id or the same words keeps the newer one, the rest are
// added, sensitive lines never are.
func Merged(mine, theirs []Entry) (out []Entry, added, updated int) {
	out = append([]Entry{}, mine...)
	for _, e := range theirs {
		if e.Text == "" || Sensitive(e.Text) {
			continue
		}
		key := strings.ToLower(e.Text)
		i := -1
		for j, o := range out {
			if o.ID == e.ID || strings.ToLower(o.Text) == key {
				i = j
				break
			}
		}
		if i < 0 {
			out = append(out, e)
			added++
			continue
		}
		if e.Date.After(out[i].Date) {
			out[i] = Entry{ID: out[i].ID, Date: e.Date, Kind: e.Kind, Topic: e.Topic, Text: e.Text}
			updated++
		}
	}
	return out, added, updated
}

// Recall: the entries most like the query, best first (character bigrams, the app's scoring).
func Recall(entries []Entry, query string, limit int) []Entry {
	type scored struct {
		e Entry
		s float64
	}
	q := Bigrams(query)
	lower := strings.ToLower(query)
	var all []scored
	for _, e := range entries {
		s := Similarity(q, Bigrams(e.Text+" "+e.Topic))
		if e.Topic != "" && strings.Contains(lower, strings.ReplaceAll(e.Topic, "-", " ")) {
			s += 0.5
		}
		if e.Kind == "preference" {
			s += 0.02
		}
		if s > 0.05 {
			all = append(all, scored{e, s})
		}
	}
	sort.SliceStable(all, func(i, j int) bool { return all[i].s > all[j].s })
	out := []Entry{}
	for i := 0; i < len(all) && i < limit; i++ {
		out = append(out, all[i].e)
	}
	return out
}

var longNumber = regexp.MustCompile(`\d[\d -]{5,}\d`)

// Sensitive: passwords, one-time codes, card / ID / long account numbers are never kept.
func Sensitive(text string) bool {
	lower := strings.ToLower(text)
	for _, w := range []string{"password", "passcode", "密码", "验证码", "verification code", "cvv", "身份证", "银行卡", "card number", "pin "} {
		if strings.Contains(lower, w) {
			return true
		}
	}
	return longNumber.MatchString(text)
}

// TopicSlug: "Bilibili App" → "bilibili-app".
func TopicSlug(s string) string {
	parts := strings.FieldsFunc(strings.ToLower(strings.TrimSpace(s)), func(r rune) bool {
		return !(unicode.IsLetter(r) || unicode.IsMark(r) || unicode.IsNumber(r) || r == '-')
	})
	return strings.Join(parts, "-")
}

// Bigrams of the lowercased text without spaces and punctuation.
func Bigrams(s string) map[string]bool {
	var rs []rune
	for _, r := range strings.ToLower(s) {
		if !unicode.IsSpace(r) && !unicode.IsPunct(r) {
			rs = append(rs, r)
		}
	}
	out := map[string]bool{}
	if len(rs) < 2 {
		for _, r := range rs {
			out[string(r)] = true
		}
		return out
	}
	for i := 0; i+1 < len(rs); i++ {
		out[string(rs[i:i+2])] = true
	}
	return out
}

// Similarity: shared bigrams over the smaller set.
func Similarity(a, b map[string]bool) float64 {
	if len(a) == 0 || len(b) == 0 {
		return 0
	}
	n := 0
	for k := range a {
		if b[k] {
			n++
		}
	}
	return float64(n) / float64(min(len(a), len(b)))
}

func validKind(k string) bool {
	for _, x := range Kinds {
		if x == k {
			return true
		}
	}
	return false
}

// Store is MEMORY.md in a directory (<config>/memory).
type Store struct{ Dir string }

func (s Store) Path() string { return filepath.Join(s.Dir, "MEMORY.md") }

func (s Store) Load() ([]Entry, error) {
	b, err := os.ReadFile(s.Path())
	if errors.Is(err, os.ErrNotExist) {
		return []Entry{}, nil
	}
	return Parse(string(b)), err
}

func (s Store) Save(entries []Entry) error {
	if err := os.MkdirAll(s.Dir, 0o700); err != nil {
		return err
	}
	tmp := s.Path() + ".tmp"
	if err := os.WriteFile(tmp, []byte(Render(entries)), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.Path())
}

// Add keeps a line unless it is empty, too long, sensitive or already known.
func (s Store) Add(text, kind, topic string) (Entry, error) {
	text = strings.ReplaceAll(strings.TrimSpace(text), "\n", " ")
	switch {
	case text == "":
		return Entry{}, errors.New("nothing to remember")
	case len([]rune(text)) > MaxChars:
		return Entry{}, errors.New("too long: at most 300 characters")
	case Sensitive(text):
		return Entry{}, errors.New("not kept: passwords, codes and card or ID numbers never are")
	}
	if kind == "" {
		kind = "fact"
	}
	if !validKind(kind) {
		return Entry{}, errors.New("kind is preference, fact or app")
	}
	entries, err := s.Load()
	if err != nil {
		return Entry{}, err
	}
	for _, e := range entries {
		if strings.EqualFold(e.Text, text) {
			return Entry{}, errors.New("already remembered (" + e.ID + ")")
		}
	}
	b := make([]byte, 4)
	_, _ = rand.Read(b)
	e := Entry{ID: hex.EncodeToString(b), Date: time.Now().Truncate(time.Second), Kind: kind, Topic: TopicSlug(topic), Text: text}
	return e, s.Save(append(entries, e))
}

// Remove drops the entry with this id.
func (s Store) Remove(id string) (Entry, error) {
	entries, err := s.Load()
	if err != nil {
		return Entry{}, err
	}
	for i, e := range entries {
		if e.ID == id {
			return e, s.Save(append(entries[:i], entries[i+1:]...))
		}
	}
	return Entry{}, errors.New("no memory with id " + id + " (memory list)")
}

// Import merges another MEMORY.md in.
func (s Store) Import(text string) (added, updated int, err error) {
	entries, err := s.Load()
	if err != nil {
		return 0, 0, err
	}
	out, added, updated := Merged(entries, Parse(text))
	if added+updated == 0 {
		return 0, 0, nil
	}
	return added, updated, s.Save(out)
}
