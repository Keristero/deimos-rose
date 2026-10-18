package editor

// The terrain brush (Stage 7): raise, lower, flatten toward a target
// height, or smooth, in a round, square or rough shape with a soft edge.

import "core:math"

import "dr:terrain"

Brush_Mode :: enum {
	Raise,
	Lower,
	Flatten,
	Smooth,
}

Brush_Shape :: enum {
	Round,
	Square,
	Rough, // round, its weight and edge broken up by noise
}

Brush :: struct {
	mode:     Brush_Mode,
	shape:    Brush_Shape,
	radius:   f32, // map pixels
	// 0-1: a dab at full strength raises or lowers by RAISE_STEP, and
	// flattens or smooths all the way.
	strength: f32,
	// 0-1: the share of the radius over which the brush fades out.
	falloff:  f32,
	target:   f32, // Flatten's height, in map pixels
}

BRUSH_DEFAULT :: Brush {
	mode     = .Raise,
	shape    = .Round,
	radius   = 24,
	strength = 0.5,
	falloff  = 0.6,
	target   = 64,
}

// Puts the brush's shape, size, strength and falloff back to BRUSH_DEFAULT.
// The mode is the tool in hand and the target a height taken from the map,
// so both stay.
brush_reset :: proc "contextless" (b: ^Brush) {
	mode, target := b.mode, b.target
	b^ = BRUSH_DEFAULT
	b.mode, b.target = mode, target
}

// Map pixels a full-strength dab raises or lowers the ground.
RAISE_STEP :: 4
// A held brush dabs this often, at full weight, when it stays still.
DABS_PER_SECOND :: 30

// One dab centred on `centre` (map pixels), at `amount` of a full one,
// recorded into the open stroke of `h`. Where the ground crosses the water
// level, a water layer follows it: ground lowered under the water is
// covered by the level's water, opaque, and ground raised out of it has
// none. Returns the region it changed.
brush_dab :: proc(p: ^terrain.Project, b: Brush, centre: [2]f32, amount: f32, h: ^History) -> (area: terrain.Rect) {
	r := max(b.radius, 0.5)
	area = terrain.rect_clip({int(math.floor(centre.x - r)), int(math.floor(centre.y - r)), int(math.ceil(centre.x + r)) + 1, int(math.ceil(centre.y + r)) + 1}, p.width, p.length)
	if area.x1 <= area.x0 || area.y1 <= area.y0 || amount <= 0 {
		return {}
	}
	history_touch(h, p, area)

	// Smoothing reads the heights as they were before this dab.
	before: []f32
	src: terrain.Rect
	if b.mode == .Smooth {
		src = terrain.rect_clip({area.x0 - 1, area.y0 - 1, area.x1 + 1, area.y1 + 1}, p.width, p.length)
		sw := src.x1 - src.x0
		before = make([]f32, sw * (src.y1 - src.y0), context.temp_allocator)
		for y in src.y0 ..< src.y1 {
			copy(before[(y - src.y0) * sw:][:sw], p.heights[y * p.width + src.x0:][:sw])
		}
	}
	strength := clamp(b.strength, 0, 1)
	for y in area.y0 ..< area.y1 {
		for x in area.x0 ..< area.x1 {
			w := brush_weight(b, {f32(x) + 0.5 - centre.x, f32(y) + 0.5 - centre.y}, x, y) * amount
			if w <= 0 {
				continue
			}
			i := y * p.width + x
			old := p.heights[i]
			v := old
			switch b.mode {
			case .Raise:
				v += RAISE_STEP * strength * w
			case .Lower:
				v -= RAISE_STEP * strength * w
			case .Flatten:
				v += (b.target - old) * min(strength * w, 1)
			case .Smooth:
				sum, n := f32(0), 0
				sw := src.x1 - src.x0
				for dy in -1 ..= 1 {
					for dx in -1 ..= 1 {
						sx, sy := x + dx, y + dy
						if sx >= src.x0 && sx < src.x1 && sy >= src.y0 && sy < src.y1 {
							sum += before[(sy - src.y0) * sw + sx - src.x0]
							n += 1
						}
					}
				}
				v += (sum / f32(n) - old) * min(strength * w, 1)
			}
			v = clamp(v, 0, terrain.HEIGHT_MAX)
			p.heights[i] = v
			water_follow(p, i, old, v)
		}
	}
	return
}

// The brush's weight at `d` from its centre, 0-1, over map pixel (x, y).
brush_weight :: proc(b: Brush, d: [2]f32, x, y: int) -> f32 {
	r := max(b.radius, 0.5)
	dist: f32
	noise := f32(1)
	switch b.shape {
	case .Round:
		dist = math.sqrt(d.x * d.x + d.y * d.y) / r
	case .Square:
		dist = max(abs(d.x), abs(d.y)) / r
	case .Rough:
		// Fixed to the map, not the brush, so dabs over the same ground
		// agree and a stroke leaves a rough surface rather than a blur.
		noise = value_noise(f32(x), f32(y), max(r / 3, 2))
		dist = math.sqrt(d.x * d.x + d.y * d.y) / (r * (0.7 + 0.3 * noise))
	}
	if dist >= 1 {
		return 0
	}
	f := clamp(b.falloff, 0, 1)
	w := f32(1)
	if inner := 1 - f; dist > inner {
		t := (dist - inner) / f
		w = 1 - t * t * (3 - 2 * t)
	}
	return b.shape == .Rough ? w * (0.3 + 0.7 * noise) : w
}

// Keeps a water layer in step with ground crossing the water level.
@(private = "file")
water_follow :: proc(p: ^terrain.Project, i: int, old, new: f32) {
	if p.water == nil {
		return
	}
	level := p.level.water.height
	px := p.water[i * 4:][:4]
	switch {
	case old >= level && new < level && px[3] == 0:
		c := p.level.water.colour
		px[0], px[1], px[2], px[3] = c.r, c.g, c.b, 255
	case old < level && new >= level:
		px[0], px[1], px[2], px[3] = 0, 0, 0, 0
	}
}

// Smooth noise, 0-1, over a lattice `cell` map pixels wide.
@(private = "file")
value_noise :: proc(x, y, cell: f32) -> f32 {
	fx, fy := x / cell, y / cell
	ix, iy := math.floor(fx), math.floor(fy)
	tx, ty := fx - ix, fy - iy
	tx, ty = tx * tx * (3 - 2 * tx), ty * ty * (3 - 2 * ty)
	a := lattice(int(ix), int(iy))
	b := lattice(int(ix) + 1, int(iy))
	c := lattice(int(ix), int(iy) + 1)
	d := lattice(int(ix) + 1, int(iy) + 1)
	return math.lerp(math.lerp(a, b, tx), math.lerp(c, d, tx), ty)
}

@(private = "file")
lattice :: proc(x, y: int) -> f32 {
	h := u32(x) * 0x8da6b343 ~ u32(y) * 0xd8163841
	h ~= h >> 13
	h *= 0x5bd1e995
	h ~= h >> 15
	return f32(h & 0xffff) / 0xffff
}
