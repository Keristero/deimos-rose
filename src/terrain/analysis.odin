package terrain

// Measuring a render against the original map: where each is in shadow,
// found the way notes/headless-3d-to-2d-pipeline.md found the originals'
// (work/pipeline-investigation/recon/common.py): a pixel much darker than
// the lit ground around it, which is not water.

import "core:slice"

// Shadow is darker than this share of the surroundings' light.
SHADOW_RATIO :: 0.66
// The surroundings: the 85th percentile of an 81-pixel square.
@(private = "file")
WINDOW :: 81
@(private = "file")
RANK :: WINDOW * WINDOW * 85 / 100
@(private = "file")
BINS :: 1024
@(private = "file")
COARSE :: 32

Shadow_Map :: struct {
	width, height: int,
	shadow:        []bool,
	// Each pixel's light as a share of the surroundings'.
	ratio:         []f32,
}

// Water in the media mask (one pixel per `cell` map pixels square): full
// blue, no red.
water_from_mask :: proc(mask: Picture, width, height, cell: int, allocator := context.allocator) -> []bool {
	water := make([]bool, width * height, allocator)
	if mask.depth != 8 || mask.channels < 3 {
		return water
	}
	for y in 0 ..< height {
		my := min(y / cell, mask.height - 1)
		for x in 0 ..< width {
			px := mask.pixels[(my * mask.width + min(x / cell, mask.width - 1)) * mask.channels:]
			water[y * width + x] = px[2] == 255 && px[0] == 0
		}
	}
	return water
}

luminance :: proc(pic: Picture, allocator := context.allocator) -> []f32 {
	l := make([]f32, pic.width * pic.height, allocator)
	for &v, i in l {
		px := pic.pixels[i * pic.channels:]
		v = pic.channels < 3 ? f32(px[0]) / 255 : (0.299 * f32(px[0]) + 0.587 * f32(px[1]) + 0.114 * f32(px[2])) / 255
	}
	return l
}

// The shadows in an 8-bit RGB picture, `water` (or nil) left out.
detect_shadows :: proc(pic: Picture, water: []bool, allocator := context.allocator) -> (m: Shadow_Map) {
	w, h := pic.width, pic.height
	m.width, m.height = w, h
	l := luminance(pic, context.temp_allocator)
	ls := make([]f32, w * h, context.temp_allocator)
	for y in 0 ..< h {
		for x in 0 ..< w {
			sum: f32
			for dy in -1 ..= 1 {
				for dx in -1 ..= 1 {
					sum += l[reflect(y + dy, h) * w + reflect(x + dx, w)]
				}
			}
			ls[y * w + x] = sum / 9
		}
	}
	ref := percentile_filter(ls, w, h, context.temp_allocator)
	m.ratio = make([]f32, w * h, allocator)
	raw := make([]bool, w * h, context.temp_allocator)
	for i in 0 ..< w * h {
		m.ratio[i] = ls[i] / max(ref[i], 1e-3)
		raw[i] = m.ratio[i] < SHADOW_RATIO && (water == nil || !water[i])
	}
	m.shadow = opening(raw, w, h, allocator)
	return
}

// Intersection over union of two masks, `ignore` (or nil) left out.
iou :: proc(a, b, ignore: []bool) -> f32 {
	inter, union_ := 0, 0
	for i in 0 ..< len(a) {
		if ignore != nil && ignore[i] {
			continue
		}
		inter += int(a[i] && b[i])
		union_ += int(a[i] || b[i])
	}
	return union_ > 0 ? f32(inter) / f32(union_) : 1
}

// The median light of shadow against its surroundings: 0.44 in the
// originals.
shadow_ratio :: proc(m: Shadow_Map) -> f32 {
	in_shadow := make([dynamic]f32, 0, len(m.shadow) / 8, context.temp_allocator)
	for s, i in m.shadow {
		if s {
			append(&in_shadow, m.ratio[i])
		}
	}
	if len(in_shadow) == 0 {
		return 1
	}
	slice.sort(in_shadow[:])
	return in_shadow[len(in_shadow) / 2]
}

// scipy's "reflect": the edge pixel repeated, then the image mirrored.
@(private = "file")
reflect :: proc "contextless" (i, n: int) -> int {
	i := i
	for i < 0 || i >= n {
		i = i < 0 ? -i - 1 : 2 * n - i - 1
	}
	return i
}

// The 85th percentile of each WINDOW-square, in BINS levels: a histogram
// slid along each row, with a coarse one to find the rank quickly.
@(private = "file")
percentile_filter :: proc(v: []f32, w, h: int, allocator := context.allocator) -> []f32 {
	bins := make([]u16, w * h, context.temp_allocator)
	for x, i in v {
		bins[i] = u16(clamp(int(x * (BINS - 1) + 0.5), 0, BINS - 1))
	}
	out := make([]f32, w * h, allocator)
	R :: WINDOW / 2
	fine: [BINS]i32
	coarse: [COARSE]i32
	column :: proc(bins: []u16, w, h, x, y: int, fine: ^[BINS]i32, coarse: ^[COARSE]i32, add: i32) {
		cx := reflect(x, w)
		for dy in -R ..= R {
			b := bins[reflect(y + dy, h) * w + cx]
			fine[b] += add
			coarse[b / (BINS / COARSE)] += add
		}
	}
	for y in 0 ..< h {
		fine, coarse = {}, {}
		for dx in -R ..= R {
			column(bins, w, h, dx, y, &fine, &coarse, 1)
		}
		for x in 0 ..< w {
			if x > 0 {
				column(bins, w, h, x - R - 1, y, &fine, &coarse, -1)
				column(bins, w, h, x + R, y, &fine, &coarse, 1)
			}
			seen: i32
			c := 0
			for c < COARSE - 1 && seen + coarse[c] <= RANK {
				seen += coarse[c]
				c += 1
			}
			b := c * (BINS / COARSE)
			for b < BINS - 1 && seen + fine[b] <= RANK {
				seen += fine[b]
				b += 1
			}
			out[y * w + x] = f32(b) / (BINS - 1)
		}
	}
	return out
}

// Erosion then dilation by the 3x3 cross, outside the picture counted as
// not set, as scipy's binary_opening.
@(private = "file")
opening :: proc(m: []bool, w, h: int, allocator := context.allocator) -> []bool {
	CROSS :: [5][2]int{{0, 0}, {1, 0}, {-1, 0}, {0, 1}, {0, -1}}
	at :: proc(m: []bool, w, h, x, y: int) -> bool {
		return x >= 0 && y >= 0 && x < w && y < h && m[y * w + x]
	}
	eroded := make([]bool, w * h, context.temp_allocator)
	out := make([]bool, w * h, allocator)
	for y in 0 ..< h {
		for x in 0 ..< w {
			all := true
			for d in CROSS {
				all &&= at(m, w, h, x + d.x, y + d.y)
			}
			eroded[y * w + x] = all
		}
	}
	for y in 0 ..< h {
		for x in 0 ..< w {
			hit := false
			for d in CROSS {
				hit ||= at(eroded, w, h, x + d.x, y + d.y)
			}
			out[y * w + x] = hit
		}
	}
	return out
}
