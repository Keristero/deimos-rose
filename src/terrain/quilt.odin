package terrain

// Image quilting (Efros and Freeman, "Image Quilting for Texture Synthesis
// and Transfer", SIGGRAPH 2001), on a torus: a material's image made from
// an exemplar of the originals' ground by laying blocks of it, each chosen
// to agree with those beside it and joined to them along the cheapest
// seam. The blocks wrap around the image's edges, the last in a row or
// column joined to the first as to its neighbours, so the image tiles.
// tools/materials makes the editor's library with it. CPU only.

import "core:math/rand"

Quilt_Options :: struct {
	size:    int, // the image's width and height: a multiple of block - overlap
	block:   int, // a block's width and height, in pixels
	overlap: int, // how far each overlaps the one before
	// Among the blocks within this much of the best's error, one is taken
	// at random: the best alone repeats itself. The paper's 0.1 repeated
	// the red dust's pebbles in a 256 tile; 0.3 did not, and seams no worse.
	tolerance: f32,
	seed:      u64,
}

QUILT_DEFAULT :: Quilt_Options {
	size      = 256,
	block     = 40,
	overlap   = 8,
	tolerance = 0.3,
	seed      = 1,
}

// A size x size RGB image quilted from `exemplar` (RGB, 8-bit, larger than
// a block), that tiles. ok false when the options do not fit.
quilt :: proc(exemplar: Picture, o: Quilt_Options, allocator := context.allocator) -> (out: Picture, ok: bool) {
	b, ov := o.block, o.overlap
	step := b - ov
	if exemplar.channels != 3 || exemplar.depth != 8 || exemplar.width < b || exemplar.height < b || ov <= 0 || step <= 0 || o.size % step != 0 || o.size < 2 * step {
		return
	}
	n := o.size / step // blocks across and down
	out = picture_make(o.size, o.size, 3, 8, allocator)
	filled := make([]bool, o.size * o.size, context.temp_allocator)
	state := rand.create(o.seed)
	gen := rand.default_random_generator(&state)

	cands_x, cands_y := exemplar.width - b + 1, exemplar.height - b + 1
	errors := make([]f32, cands_x * cands_y, context.temp_allocator)
	cost := make([]f32, b * b, context.temp_allocator)
	take := make([]bool, b * b, context.temp_allocator)
	for j in 0 ..< n {
		for i in 0 ..< n {
			x0, y0 := i * step, j * step
			// The error of every block of the exemplar against what is laid.
			best := max(f32)
			for cy in 0 ..< cands_y {
				for cx in 0 ..< cands_x {
					e := f32(0)
					for y in 0 ..< b {
						oy := (y0 + y) % o.size
						for x in 0 ..< b {
							k := oy * o.size + (x0 + x) % o.size
							if !filled[k] {
								continue
							}
							e += pixel_error(out.pixels[k * 3:], exemplar.pixels[((cy + y) * exemplar.width + cx + x) * 3:])
						}
					}
					errors[cy * cands_x + cx] = e
					best = min(best, e)
				}
			}
			limit := best * (1 + o.tolerance)
			count := 0
			for e in errors {
				if e <= limit {
					count += 1
				}
			}
			pick := rand.int_max(count, gen)
			cx, cy := 0, 0
			for e, k in errors {
				if e > limit {
					continue
				}
				if pick == 0 {
					cx, cy = k % cands_x, k / cands_x
					break
				}
				pick -= 1
			}
			// The seams: where the block meets what is laid on each side
			// that is, the cheapest path through the overlap.
			for y in 0 ..< b {
				for x in 0 ..< b {
					k := ((y0 + y) % o.size) * o.size + (x0 + x) % o.size
					cost[y * b + x] = filled[k] ? pixel_error(out.pixels[k * 3:], exemplar.pixels[((cy + y) * exemplar.width + cx + x) * 3:]) : 0
				}
			}
			for &t in take {
				t = true
			}
			if i > 0 {
				seam(cost, take, b, ov, .Left)
			}
			if i == n - 1 {
				seam(cost, take, b, ov, .Right)
			}
			if j > 0 {
				seam(cost, take, b, ov, .Top)
			}
			if j == n - 1 {
				seam(cost, take, b, ov, .Bottom)
			}
			for y in 0 ..< b {
				for x in 0 ..< b {
					k := ((y0 + y) % o.size) * o.size + (x0 + x) % o.size
					if take[y * b + x] || !filled[k] {
						copy(out.pixels[k * 3:][:3], exemplar.pixels[((cy + y) * exemplar.width + cx + x) * 3:][:3])
						filled[k] = true
					}
				}
			}
		}
	}
	return out, true
}

@(private = "file")
pixel_error :: #force_inline proc(a, b: []u8) -> f32 {
	e := f32(0)
	for c in 0 ..< 3 {
		d := f32(a[c]) - f32(b[c])
		e += d * d
	}
	return e
}

@(private = "file")
Side :: enum {
	Left,
	Right,
	Top,
	Bottom,
}

// The cheapest path along the overlap on `side`, from one end of the block
// to the other, moving at most a pixel across a step; what is beyond it,
// toward the side, stays as laid. Dynamic programming, as the paper's.
@(private = "file")
seam :: proc(cost: []f32, take: []bool, b, ov: int, side: Side) {
	// (along, across) to the block's cost index: along runs the block's
	// length, across the overlap's depth from the side inward.
	at :: proc(b, ov: int, side: Side, along, across: int) -> int {
		switch side {
		case .Left:
			return along * b + across
		case .Right:
			return along * b + b - 1 - across
		case .Top:
			return across * b + along
		case .Bottom:
			return (b - 1 - across) * b + along
		}
		unreachable()
	}
	acc := make([]f32, b * ov, context.temp_allocator)
	for a in 0 ..< b {
		for d in 0 ..< ov {
			c := cost[at(b, ov, side, a, d)]
			if a > 0 {
				m := acc[(a - 1) * ov + d]
				if d > 0 {
					m = min(m, acc[(a - 1) * ov + d - 1])
				}
				if d < ov - 1 {
					m = min(m, acc[(a - 1) * ov + d + 1])
				}
				c += m
			}
			acc[a * ov + d] = c
		}
	}
	d := 0
	for k in 1 ..< ov {
		if acc[(b - 1) * ov + k] < acc[(b - 1) * ov + d] {
			d = k
		}
	}
	for a := b - 1; a >= 0; a -= 1 {
		// The path's pixel is the new block's; those toward the side are not.
		for k in 0 ..< d {
			take[at(b, ov, side, a, k)] = false
		}
		if a > 0 {
			next := d
			for k in max(d - 1, 0) ..= min(d + 1, ov - 1) {
				if acc[(a - 1) * ov + k] < acc[(a - 1) * ov + next] {
					next = k
				}
			}
			d = next
		}
	}
}

// The size x size window of `pic` (RGB, 8-bit) inside `within` that is most
// alike throughout: the least spread of its cell x cell blocks' mean
// colours, so one ground and not an edge between two, nor a gradient.
uniform_window :: proc(pic: Picture, within: Rect, size, cell: int) -> (x, y: int, spread: f32, ok: bool) {
	box := rect_clip(within, pic.width, pic.height)
	if box.x1 - box.x0 < size || box.y1 - box.y0 < size || cell <= 0 || size % cell != 0 {
		return
	}
	cells := size / cell
	best := max(f32)
	means := make([][3]f32, cells * cells, context.temp_allocator)
	// A cell's step: every window a cell apart, the box's own grid.
	for wy := box.y0; wy + size <= box.y1; wy += cell {
		for wx := box.x0; wx + size <= box.x1; wx += cell {
			total: [3]f32
			for cy in 0 ..< cells {
				for cx in 0 ..< cells {
					m: [3]f32
					for py in 0 ..< cell {
						row := pic.pixels[((wy + cy * cell + py) * pic.width + wx + cx * cell) * 3:]
						for px in 0 ..< cell {
							m += {f32(row[px * 3]), f32(row[px * 3 + 1]), f32(row[px * 3 + 2])}
						}
					}
					m /= f32(cell * cell)
					means[cy * cells + cx] = m
					total += m
				}
			}
			total /= f32(cells * cells)
			s := f32(0)
			for m in means {
				d := m - total
				s += d.x * d.x + d.y * d.y + d.z * d.z
			}
			s /= f32(cells * cells)
			if s < best {
				best, x, y = s, wx, wy
			}
		}
	}
	return x, y, best, true
}

// The window of `pic` at (x, y), w x h, as a picture of its own.
picture_crop :: proc(pic: Picture, x, y, w, h: int, allocator := context.allocator) -> Picture {
	out := picture_make(w, h, pic.channels, pic.depth, allocator)
	stride := pic.channels * pic.depth / 8
	for row in 0 ..< h {
		copy(out.pixels[row * w * stride:][:w * stride], pic.pixels[((y + row) * pic.width + x) * stride:][:w * stride])
	}
	return out
}
