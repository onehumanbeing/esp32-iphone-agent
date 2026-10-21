package pointer

import (
	"image"
	"image/color"
	"testing"
)

func fill(w, h int, c color.Gray) *image.Gray {
	img := image.NewGray(image.Rect(0, 0, w, h))
	for i := range img.Pix {
		img.Pix[i] = c.Y
	}
	return img
}

func TestChanged(t *testing.T) {
	a := fill(200, 400, color.Gray{20})
	dot := fill(200, 400, color.Gray{20})
	for y := 100; y < 110; y++ { // a pointer-sized spot
		for x := 50; x < 60; x++ {
			dot.Pix[y*200+x] = 200
		}
	}
	if Changed(a, dot, 0.05) {
		t.Error("a pointer-sized change counted as a new screen")
	}
	if !Changed(a, fill(200, 400, color.Gray{230}), 0.05) {
		t.Error("a new screen not seen")
	}
}
