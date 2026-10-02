package terrain

// A level's preview, the thumbnail Level Select shows, made as the
// originals' were (notes/headless-3d-to-2d-findings.md): a 438x918 crop
// of the map, downscaled exactly 3x, then given a vignette and a warmer,
// softer tone. The look, PREVIEW_LOOK, is fitted to the twelve originals
// by tools/preview_fit (preview_look.odin).

import "core:math"

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
// the level, its bottom, as most of the originals' were.
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
