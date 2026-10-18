package terrain

// A level's preview, the thumbnail Level Select shows, made as the
// originals' were (notes/headless-3d-to-2d-findings.md): a 438x918 crop
// of the map, downscaled exactly 3x, then given a vignette and a warmer,
// softer tone. The look, PREVIEW_LOOK, is fitted to the twelve originals
// by tools/preview_fit (preview_look.odin).

import "core:math"
import "core:slice"

PREVIEW_WIDTH :: 146
PREVIEW_HEIGHT :: 306
PREVIEW_DOWNSCALE :: 3
PREVIEW_CROP_WIDTH :: PREVIEW_WIDTH * PREVIEW_DOWNSCALE // 438
PREVIEW_CROP_HEIGHT :: PREVIEW_HEIGHT * PREVIEW_DOWNSCALE // 918
PREVIEW_TONE_KNOTS :: 17
PREVIEW_VIGNETTE_KNOTS :: 9

// With s = colour * (blur(crop / 3), 1), the colour mixed:
//   out_c = across(|x|) * down(|y|) * tone_c(s_c)
// The colour carries the warmth and the saturation, which curves on each
// channel alone cannot; the tone, the contrast. Each curve is piecewise
// linear: the tone's knots evenly over 0-255, the vignette's over the
// distance from the middle, 0 there to 1 at the edge. The originals'
// vignette darkens the sides more than the ends, so it is two curves.
Preview_Look :: struct {
	blur:   f32, // a Gaussian's sigma, in preview pixels
	colour: [3][4]f32, // each output channel's mix of R, G, B, and an offset
	tone:   [3][PREVIEW_TONE_KNOTS]f32,
	across: [PREVIEW_VIGNETTE_KNOTS]f32,
	down:   [PREVIEW_VIGNETTE_KNOTS]f32,
}

// How far a preview pixel is from the middle, across and down: 0 there,
// 1 at the edges.
preview_distance :: proc "contextless" (x, y: int) -> [2]f32 {
	return {abs((f32(x) + 0.5) / PREVIEW_WIDTH * 2 - 1), abs((f32(y) + 0.5) / PREVIEW_HEIGHT * 2 - 1)}
}

// The vignette's factor at a preview pixel.
preview_vignette :: proc(look: ^Preview_Look, x, y: int) -> f32 {
	d := preview_distance(x, y)
	return preview_curve(look.across[:], d.x, 1) * preview_curve(look.down[:], d.y, 1)
}

// A downscaled pixel's colour mixed, before the tone.
preview_mix :: proc "contextless" (look: ^Preview_Look, rgb: [3]f32) -> (s: [3]f32) {
	for c in 0 ..< 3 {
		m := look.colour[c]
		s[c] = m[0] * rgb[0] + m[1] * rgb[1] + m[2] * rgb[2] + m[3]
	}
	return
}

// A piecewise linear curve's value at `v`, its knots evenly over [0, top].
preview_curve :: proc "contextless" (knots: []f32, v, top: f32) -> f32 {
	t := clamp(v / top, 0, 1) * f32(len(knots) - 1)
	k := min(int(t), len(knots) - 2)
	f := t - f32(k)
	return knots[k] * (1 - f) + knots[k + 1] * f
}

// Where a crop goes by default: the map's middle across, and the start of
// the level, its bottom, which the player sees first. The originals' were
// anywhere (preview_look.odin lists them): only three are at the bottom.
preview_crop_default :: proc(width, length: int) -> [2]int {
	return preview_crop_clamp({(width - PREVIEW_CROP_WIDTH) / 2, length - PREVIEW_CROP_HEIGHT}, width, length)
}

// A crop's top left kept on the map, where it fits.
preview_crop_clamp :: proc(at: [2]int, width, length: int) -> [2]int {
	return {clamp(at.x, 0, max(width - PREVIEW_CROP_WIDTH, 0)), clamp(at.y, 0, max(length - PREVIEW_CROP_HEIGHT, 0))}
}

// The crop at `at` (its top left, in map pixels) of an RGB map, averaged
// down 3x and blurred by `blur`: RGB floats, PREVIEW_WIDTH x PREVIEW_HEIGHT.
// A map smaller than the crop repeats its edge.
preview_crop :: proc(m: Picture, at: [2]int, blur: f32, allocator := context.allocator) -> []f32 {
	out := make([]f32, PREVIEW_WIDTH * PREVIEW_HEIGHT * 3, allocator)
	for y in 0 ..< PREVIEW_HEIGHT {
		for x in 0 ..< PREVIEW_WIDTH {
			sum: [3]f32
			for dy in 0 ..< PREVIEW_DOWNSCALE {
				for dx in 0 ..< PREVIEW_DOWNSCALE {
					mx := clamp(at.x + x * PREVIEW_DOWNSCALE + dx, 0, m.width - 1)
					my := clamp(at.y + y * PREVIEW_DOWNSCALE + dy, 0, m.height - 1)
					px := m.pixels[(my * m.width + mx) * m.channels:]
					for c in 0 ..< 3 {
						sum[c] += f32(px[c])
					}
				}
			}
			for c in 0 ..< 3 {
				out[(y * PREVIEW_WIDTH + x) * 3 + c] = sum[c] / (PREVIEW_DOWNSCALE * PREVIEW_DOWNSCALE)
			}
		}
	}
	if blur > 0 {
		gaussian_rgb(out, PREVIEW_WIDTH, PREVIEW_HEIGHT, blur)
	}
	return out
}

// The preview of an RGB map with its crop at `at`.
preview_make :: proc(m: Picture, at: [2]int, allocator := context.allocator) -> Picture {
	return preview_make_with(m, at, PREVIEW_LOOK, allocator)
}

preview_make_with :: proc(m: Picture, at: [2]int, look: Preview_Look, allocator := context.allocator) -> Picture {
	look := look
	src := preview_crop(m, at, look.blur, context.temp_allocator)
	pic := picture_make(PREVIEW_WIDTH, PREVIEW_HEIGHT, 3, 8, allocator)
	for y in 0 ..< PREVIEW_HEIGHT {
		for x in 0 ..< PREVIEW_WIDTH {
			v := preview_vignette(&look, x, y)
			i := (y * PREVIEW_WIDTH + x) * 3
			s := preview_mix(&look, {src[i], src[i + 1], src[i + 2]})
			for c in 0 ..< 3 {
				pic.pixels[i + c] = u8(clamp(math.round(v * preview_curve(look.tone[c][:], s[c], 255)), 0, 255))
			}
		}
	}
	return pic
}

// Where `preview` was cut from the RGB map `m`, as preview_crop takes it:
// the best normalised correlation of its luminance with the map's,
// downscaled 3x at each of the 9 phases, over the preview's middle, where
// the vignette is faint; and that correlation. A coarse pass on every
// third pixel, then the best few again on all of them. Finds the
// originals' crops for tools/preview_fit and for their recovered projects
// (`terrain preview`).
preview_locate :: proc(m, preview: Picture) -> (at: [2]int, score: f32) {
	D :: PREVIEW_DOWNSCALE
	Candidate :: struct {
		at:    [2]int,
		score: f32,
	}
	Point :: struct {
		x, y: int,
		v:    f32,
	}
	points :: proc(lum: []f32, step: int) -> []Point {
		out := make([dynamic]Point, context.temp_allocator)
		mean: f32
		for y := 0; y < PREVIEW_HEIGHT; y += step {
			for x := 0; x < PREVIEW_WIDTH; x += step {
				if d := preview_distance(x, y); d.x < 0.6 && d.y < 0.6 {
					v := lum[y * PREVIEW_WIDTH + x]
					append(&out, Point{x, y, v})
					mean += v
				}
			}
		}
		mean /= f32(len(out))
		norm: f32
		for &q in out {
			q.v -= mean
			norm += q.v * q.v
		}
		norm = math.sqrt(norm)
		for &q in out {
			q.v /= norm
		}
		return out[:]
	}
	// The map's luminance downscaled at each phase.
	Small :: struct {
		w, h: int,
		v:    []f32,
	}
	full := luminance(m, context.temp_allocator)
	smalls: [D][D]Small
	for py in 0 ..< D {
		for px in 0 ..< D {
			s := &smalls[py][px]
			s.w, s.h = (m.width - px) / D, (m.height - py) / D
			s.v = make([]f32, s.w * s.h, context.temp_allocator)
			for row in 0 ..< s.h {
				for col in 0 ..< s.w {
					sum: f32
					for dy in 0 ..< D {
						for dx in 0 ..< D {
							sum += full[(py + row * D + dy) * m.width + px + col * D + dx]
						}
					}
					s.v[row * s.w + col] = sum / (D * D)
				}
			}
		}
	}
	ncc :: proc(s: ^Small, pts: []Point, ox, oy: int) -> f32 {
		mean, dot, sq: f32
		for q in pts {
			mean += s.v[(oy + q.y) * s.w + ox + q.x]
		}
		mean /= f32(len(pts))
		for q in pts {
			v := s.v[(oy + q.y) * s.w + ox + q.x] - mean
			dot += v * q.v
			sq += v * v
		}
		return sq > 0 ? dot / math.sqrt(sq) : 0
	}
	lum := luminance(preview, context.temp_allocator)
	coarse := points(lum, 3)
	fine := points(lum, 1)
	best := make([dynamic]Candidate, context.temp_allocator)
	for py in 0 ..< D {
		for px in 0 ..< D {
			s := &smalls[py][px]
			for oy in 0 ..= s.h - PREVIEW_HEIGHT {
				for ox in 0 ..= s.w - PREVIEW_WIDTH {
					c := ncc(s, coarse, ox, oy)
					if len(best) < 8 || c > best[len(best) - 1].score {
						append(&best, Candidate{{px + ox * D, py + oy * D}, c})
						slice.sort_by(best[:], proc(a, b: Candidate) -> bool {return a.score > b.score})
						if len(best) > 8 {
							pop(&best)
						}
					}
				}
			}
		}
	}
	score = -1
	for c in best {
		s := &smalls[c.at.y % D][c.at.x % D]
		if f := ncc(s, fine, c.at.x / D, c.at.y / D); f > score {
			at, score = c.at, f
		}
	}
	return
}

// A separable Gaussian over an RGB float image, its edges repeated.
@(private = "file")
gaussian_rgb :: proc(px: []f32, w, h: int, sigma: f32) {
	r := int(math.ceil(3 * sigma))
	kernel := make([]f32, 2 * r + 1, context.temp_allocator)
	total: f32
	for k in -r ..= r {
		kernel[k + r] = math.exp(-f32(k * k) / (2 * sigma * sigma))
		total += kernel[k + r]
	}
	for &k in kernel {
		k /= total
	}
	tmp := make([]f32, len(px), context.temp_allocator)
	for pass in 0 ..< 2 {
		src, dst := pass == 0 ? px : tmp, pass == 0 ? tmp : px
		for y in 0 ..< h {
			for x in 0 ..< w {
				sum: [3]f32
				for k in -r ..= r {
					sx, sy := x, y
					if pass == 0 {
						sx = clamp(x + k, 0, w - 1)
					} else {
						sy = clamp(y + k, 0, h - 1)
					}
					for c in 0 ..< 3 {
						sum[c] += kernel[k + r] * src[(sy * w + sx) * 3 + c]
					}
				}
				for c in 0 ..< 3 {
					dst[(y * w + x) * 3 + c] = sum[c]
				}
			}
		}
	}
}
