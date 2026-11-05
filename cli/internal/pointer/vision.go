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
	return LocateBack(before, after, nil, near, shift, reach)
}

// LocateBack is Locate with back, a frame after the pointer moved back where it was in before: only pixels that
// changed there and back count, so a clock's second hand or an animation elsewhere is not taken for the pointer
// (2026-11-06: the Clock icon next to the calibration stop). back nil: as Locate.
func LocateBack(before, after, back image.Image, near Point, shift float64, reach Point) (Point, bool) {
	if before == nil || after == nil || before.Bounds().Size() != after.Bounds().Size() {
		return Point{}, false
	}
	if back != nil && back.Bounds().Size() != before.Bounds().Size() {
		back = nil
	}
	a, b := ToGray(before), ToGray(after)
	var c *Gray
	if back != nil {
		g := ToGray(back)
		c = &g
	}
	w, h := a.W, a.H
	fw, fh := float64(w), float64(h)
	left := max(0, int((near.X-reach.X)*fw))
	top := max(int(0.05*fh), int((near.Y-reach.Y)*fh)) // skip the status bar
	right, bottom := min(w, int((near.X+reach.X)*fw)), min(h, int((near.Y+reach.Y)*fh))
	if right <= left || bottom <= top {
		return Point{}, false
	}
	var pts [][2]int
	for y := top; y < bottom; y++ {
		for x := left; x < right; x++ {
			i := y*w + x
			if d := int(a.Px[i]) - int(b.Px[i]); d <= 30 && d >= -30 {
				continue
			}
			if c != nil {
				if d := int(c.Px[i]) - int(b.Px[i]); d <= 30 && d >= -30 {
					continue // not moved back
				}
				if d := int(c.Px[i]) - int(a.Px[i]); d > 30 || d < -30 {
					continue // changed on its own
				}
			}
			pts = append(pts, [2]int{x, y})
		}
	}
	pts = biggestBlob(pts, max(4, w/80))
	n, sx, sy := len(pts), 0, 0
	minX, maxX, minY, maxY := w, -1, h, -1
	for _, p := range pts {
		x, y := p[0], p[1]
		sx += x - left
		sy += y - top
		minX, maxX, minY, maxY = min(minX, x), max(maxX, x), min(minY, y), max(maxY, y)
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

// biggestBlob keeps the changed pixels of the largest spot: pixels in cells of size cell, cells touching (8-way)
// form one spot. The pointer is a filled disc; a clock's second hand or a badge elsewhere is a separate, thinner one.
func biggestBlob(pts [][2]int, cell int) [][2]int {
	cells := map[[2]int][]int{} // cell → indexes into pts
	for i, p := range pts {
		k := [2]int{p[0] / cell, p[1] / cell}
		cells[k] = append(cells[k], i)
	}
	seen := map[[2]int]bool{}
	var best []int
	for k := range cells {
		if seen[k] {
			continue
		}
		var blob []int
		stack := [][2]int{k}
		seen[k] = true
		for len(stack) > 0 {
			q := stack[len(stack)-1]
			stack = stack[:len(stack)-1]
			blob = append(blob, cells[q]...)
			for dy := -1; dy <= 1; dy++ {
				for dx := -1; dx <= 1; dx++ {
					nb := [2]int{q[0] + dx, q[1] + dy}
					if _, ok := cells[nb]; ok && !seen[nb] {
						seen[nb] = true
						stack = append(stack, nb)
					}
				}
			}
		}
		if len(blob) > len(best) {
			best = blob
		}
	}
	out := make([][2]int, len(best))
	for i, j := range best {
		out[i] = pts[j]
	}
	return out
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
