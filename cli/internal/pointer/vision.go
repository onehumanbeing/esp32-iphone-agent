package pointer

import "image"

// Gray is a grayscale bitmap (PIL "L" weights), row-major.
type Gray struct {
	W, H int
	Px   []uint8
}

// ToGray converts a frame like PIL's convert("L").
func ToGray(img image.Image) Gray {
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	g := Gray{W: w, H: h, Px: make([]uint8, w*h)}
	lum := func(r, gg, bb int) uint8 { return uint8((r*299 + gg*587 + bb*114 + 500) / 1000) }
	if rgba, ok := img.(*image.RGBA); ok {
		for y := 0; y < h; y++ {
			row := rgba.Pix[y*rgba.Stride:]
			for x := 0; x < w; x++ {
				g.Px[y*w+x] = lum(int(row[4*x]), int(row[4*x+1]), int(row[4*x+2]))
			}
		}
		return g
	}
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			r, gg, bb, _ := img.At(b.Min.X+x, b.Min.Y+y).RGBA()
			g.Px[y*w+x] = lum(int(r>>8), int(gg>>8), int(bb>>8))
		}
	}
	return g
}

// Point is a screen position as fractions (0..1, origin top-left).
type Point struct{ X, Y float64 }

// Locate finds the pointer in `before`, given it moved right by `shift` (fraction of width) in `after`.
//
// Only the pointer moved between the two frames, so the changed pixels within `reach` of `near` are the
// pointer at both spots; their centroid sits shift/2 to the right of the first one. ok=false if unclear.
func Locate(before, after image.Image, near Point, shift float64, reach Point) (Point, bool) {
	if before == nil || after == nil || before.Bounds().Size() != after.Bounds().Size() {
		return Point{}, false
	}
	a, b := ToGray(before), ToGray(after)
	w, h := a.W, a.H
	fw, fh := float64(w), float64(h)
	left := max(0, int((near.X-reach.X)*fw))
	top := max(int(0.05*fh), int((near.Y-reach.Y)*fh)) // skip the status bar
	right, bottom := min(w, int((near.X+reach.X)*fw)), min(h, int((near.Y+reach.Y)*fh))
	if right <= left || bottom <= top {
		return Point{}, false
	}
	n, sx, sy := 0, 0, 0
	minX, maxX, minY, maxY := w, -1, h, -1
	for y := top; y < bottom; y++ {
		for x := left; x < right; x++ {
			d := int(a.Px[y*w+x]) - int(b.Px[y*w+x])
			if d > 30 || d < -30 {
				n++
				sx += x - left
				sy += y - top
				minX, maxX, minY, maxY = min(minX, x), max(maxX, x), min(minY, y), max(maxY, y)
			}
		}
	}
	area := (right - left) * (bottom - top)
	if n < 15 || n > area/4 { // nothing moved, or more than a pointer
		return Point{}, false
	}
	if float64(maxX-minX) > 0.15*fw || float64(maxY-minY) > 0.07*fh {
		return Point{}, false // not one compact spot
	}
	cx := float64(sx)/float64(n) + float64(left)
	cy := float64(sy)/float64(n) + float64(top)
	return Point{cx/fw - shift/2, cy / fh}, true
}

// Changed reports whether more than `frac` of a coarse grid of pixels differ clearly between two frames, so a
// moved pointer or a ticking clock doesn't count but a new screen does.
func Changed(a, b image.Image, frac float64) bool {
	if a == nil || b == nil || a.Bounds() != b.Bounds() {
		return a != b
	}
	ga, gb := ToGray(a), ToGray(b)
	const grid = 64
	n, diff := 0, 0
	for gy := 0; gy < grid; gy++ {
		for gx := 0; gx < grid; gx++ {
			i := (gy*ga.H/grid)*ga.W + gx*ga.W/grid
			d := int(ga.Px[i]) - int(gb.Px[i])
			if d > 24 || d < -24 {
				diff++
			}
			n++
		}
	}
	return float64(diff) > frac*float64(n)
}
