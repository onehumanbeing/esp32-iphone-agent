package pointer

import (
	"strings"
	"unicode"

	"github.com/mozillazg/go-pinyin"
	"golang.org/x/text/unicode/norm"
)

var pinyinArgs = pinyin.NewArgs() // toneless, first reading of a heteronym

func isHan(r rune) bool { return r >= 0x4e00 && r <= 0x9fff || r >= 0x3400 && r <= 0x4dbf }

// HasHan: text has Chinese characters (typed as pinyin).
func HasHan(text string) bool { return strings.ContainsFunc(text, isHan) }

// Typeable turns text into what the board can type (printable ASCII, one key per character):
// "卫生纸 3卷" → "weishengzhi 3juan". Han characters become joined toneless pinyin (ü as v, as the iOS
// pinyin keyboard takes it), accents are folded, the rest is dropped.
func Typeable(text string) string {
	ascii := true
	for _, r := range text {
		if r < 0x20 || r > 0x7e {
			ascii = false
			break
		}
	}
	if ascii {
		return text
	}
	var out strings.Builder
	for _, r := range text {
		if isHan(r) {
			if p := pinyin.SinglePinyin(r, pinyinArgs); len(p) > 0 {
				out.WriteString(p[0])
			}
			continue
		}
		for _, d := range norm.NFD.String(string(r)) {
			if d >= 0x20 && d <= 0x7e && !unicode.Is(unicode.Mn, d) {
				out.WriteRune(d)
			}
		}
	}
	return strings.Trim(out.String(), " ")
}
