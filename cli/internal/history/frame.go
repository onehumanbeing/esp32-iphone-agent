package history

import (
	"bytes"
	"image"
	"image/color"
	"image/jpeg"

	"golang.org/x/image/draw"
)

// Width and Quality of saved screens (the app's IntentShare: 480 wide, JPEG 0.6).
const (
	Width   = 480
	Quality = 60
)

// Thumb is img scaled down to Width as a JPEG, with the top `band` share blacked out (0: none).
func Thumb(img image.Image, band float64) []byte {
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	if w > Width {
		w, h = Width, max(1, h*Width/w)
	}
	dst := image.NewRGBA(image.Rect(0, 0, w, h))
	draw.ApproxBiLinear.Scale(dst, dst.Bounds(), img, b, draw.Src, nil)
	if band > 0 {
		draw.Draw(dst, image.Rect(0, 0, w, int(float64(h)*band+0.5)), image.NewUniform(color.Black), image.Point{}, draw.Src)
	}
	var buf bytes.Buffer
	jpeg.Encode(&buf, dst, &jpeg.Options{Quality: Quality})
	return buf.Bytes()
}
