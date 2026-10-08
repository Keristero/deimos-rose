package water_view

// Ripples: where a shot to the ground lands in the water, a wave goes out
// from it, bounces off the shore and the banks, and dies away. The water is
// a height field on a grid of RIPPLE_CELL background pixels over the whole
// level, the wave equation stepped once a simulation step on the CPU; the
// land is a wall (a wave reflects off it, as water does), and only the
// rows near the view run, so what scrolled out of sight is let go. The
// shader reads the heights as one more texture and bends the reflection by
// their slope, as it does the wind's waves.
//
// The speed is slow on purpose: the game is drawn from so high up that a
// wave crossing a river in a second would look like a flash, so it crosses
// at about a fifth of the play field a second.
//
// A landing is a shot that fell (render.fall_of) and now has: the Plasma
// Bomb, which lands in the step its state turns to "Dwindle & Delete".
//
// Provisional: the size of the kick, the speed and the damping were picked
// by eye.

import "core:math"

import rl "vendor:raylib"

import "dr:render"
import "dr:sim"

@(private = "file") RIPPLE_CELL :: 2 // background pixels a cell
@(private = "file") RIPPLE_SPEED2 :: 0.09 // the square of a wave's speed, in cells a step
@(private = "file") RIPPLE_DAMPING :: 0.994 // what a wave keeps of itself each step
@(private = "file") RIPPLE_MARGIN :: 160 // background pixels beyond the view that run
@(private = "file") RIPPLE_SIGMA :: 2.0 // the splash's width, in cells
@(private = "file") RIPPLE_KICK :: 1.0 // its depth
@(private = "file") RIPPLE_AWAKE :: 900 // steps the field runs after a splash, till it has died away

@(private)
Ripples :: struct {
	w, h:    int, // the grid, in cells
	media:   []u16, // the level's media, the water in it
	media_w: int,
	scale:   int, // background pixels a media pixel
	wet:     []bool,
	now:     []f32,
	before:  []f32,
	next:    []f32,
	tex:     rl.Texture2D, // `now`, one float a cell
	lo, hi:  int, // the rows run last step
	awake:   int, // steps left to run
	flying:  [dynamic]i32, // the shots in the air a step ago, by entity number
}

// Builds the grid for a level with water in `size` background pixels.
ripples_build :: proc(media: []u16, media_w, scale: int, size: [2]f32) {
	ripples_clear()
	w, h := int(math.ceil(size.x / RIPPLE_CELL)), int(math.ceil(size.y / RIPPLE_CELL))
	shared.rip = {
		w       = w,
		h       = h,
		media   = media,
		media_w = media_w,
		scale   = scale,
		wet     = make([]bool, w * h),
		now     = make([]f32, w * h),
		before  = make([]f32, w * h),
		next    = make([]f32, w * h),
	}
	for y in 0 ..< h {
		for x in 0 ..< w {
			shared.rip.wet[y * w + x] = water_at(x * RIPPLE_CELL + RIPPLE_CELL / 2, y * RIPPLE_CELL + RIPPLE_CELL / 2)
		}
	}
	img := rl.Image{data = raw_data(shared.rip.now), width = i32(w), height = i32(h), mipmaps = 1, format = .UNCOMPRESSED_R32}
	shared.rip.tex = rl.LoadTextureFromImage(img)
	rl.SetTextureFilter(shared.rip.tex, .BILINEAR)
	rl.SetTextureWrap(shared.rip.tex, .CLAMP)
}

// Whether the background pixel is water, by the media mask.
@(private = "file")
water_at :: proc(x, y: int) -> bool {
	mx, my := x / shared.rip.scale, y / shared.rip.scale
	i := my * shared.rip.media_w + mx
	return mx >= 0 && my >= 0 && mx < shared.rip.media_w && i < len(shared.rip.media) && shared.rip.media[i] == 0x1f
}

ripples_clear :: proc() {
	if shared.rip.tex.id != 0 {
		rl.UnloadTexture(shared.rip.tex)
	}
	delete(shared.rip.wet)
	delete(shared.rip.now)
	delete(shared.rip.before)
	delete(shared.rip.next)
	delete(shared.rip.flying)
	shared.rip = {}
}

// A splash at a background pixel: a dip that spreads as a ring, still at
// first.
@(private = "file")
ripples_splash :: proc(x, y: f32) {
	cx, cy := int(x) / RIPPLE_CELL, int(y) / RIPPLE_CELL
	reach := int(RIPPLE_SIGMA * 3)
	for dy in -reach ..= reach {
		for dx in -reach ..= reach {
			px, py := cx + dx, cy + dy
			if px < 0 || py < 0 || px >= shared.rip.w || py >= shared.rip.h || !shared.rip.wet[py * shared.rip.w + px] {
				continue
			}
			d2 := f32(dx * dx + dy * dy)
			v := -RIPPLE_KICK * math.exp(-d2 / (2 * RIPPLE_SIGMA * RIPPLE_SIGMA))
			shared.rip.now[py * shared.rip.w + px] += v
			shared.rip.before[py * shared.rip.w + px] += v
		}
	}
	shared.rip.awake = RIPPLE_AWAKE
}

// Finds the shots that landed this step, and splashes those in the water.
@(private = "file")
ripples_landings :: proc(s: ^sim.State) {
	bg := sim.single(s, sim.Bgnd)
	left := f32(max(bg.side_scroll + 32, 0))
	still := make([dynamic]i32, 0, len(shared.rip.flying), context.temp_allocator)
	walk := sim.walk_entities(s)
	for e in sim.walk_next(&walk) {
		if e.owner_player < 0 {
			continue
		}
		u := &s.defs.units[e.unit]
		fall := render.fall_of(s, e, u)
		if fall < 0 {
			continue
		}
		if fall < 1 {
			append(&still, e.number)
			continue
		}
		was := false
		for n in shared.rip.flying {
			was ||= n == e.number
		}
		if !was {
			continue
		}
		// Where it is on the screen, and so on the background.
		x := f32(sim.trunc_i32(e.obj.loc.x))
		if e.obj.scrolls_sideways {
			x -= f32(bg.side_scroll)
		}
		y := f32(bg.view_top) + f32(sim.trunc_i32(e.obj.loc.y))
		if water_at(int(left + x), int(y)) {
			ripples_splash(left + x, y)
		}
	}
	clear(&shared.rip.flying)
	append(&shared.rip.flying, ..still[:])
}

// One simulation step of the ripples.
ripples_step :: proc(s: ^sim.State) {
	if shared.rip.tex.id == 0 {
		return
	}
	ripples_landings(s)
	if shared.rip.awake <= 0 {
		return
	}
	bg := sim.single(s, sim.Bgnd)
	lo := clamp((int(bg.view_top) - RIPPLE_MARGIN) / RIPPLE_CELL, 0, shared.rip.h)
	hi := clamp((int(bg.view_top) + int(render.PLAY_H) + RIPPLE_MARGIN) / RIPPLE_CELL, 0, shared.rip.h)
	// What fell out of the rows run lets go.
	for y in shared.rip.lo ..< shared.rip.hi {
		if y < lo || y >= hi {
			for x in 0 ..< shared.rip.w {
				shared.rip.now[y * shared.rip.w + x], shared.rip.before[y * shared.rip.w + x] = 0, 0
			}
		}
	}
	shared.rip.lo, shared.rip.hi = lo, hi
	w := shared.rip.w
	for y in lo ..< hi {
		for x in 0 ..< w {
			i := y * w + x
			if !shared.rip.wet[i] {
				shared.rip.next[i] = 0
				continue
			}
			// A neighbour that is land or off the map reflects: it reads as
			// this cell's own height, so no wave goes through it.
			u := shared.rip.now[i]
			l, r_, a, b := u, u, u, u
			if x > 0 && shared.rip.wet[i - 1] {l = shared.rip.now[i - 1]}
			if x < w - 1 && shared.rip.wet[i + 1] {r_ = shared.rip.now[i + 1]}
			if y > 0 && shared.rip.wet[i - w] {a = shared.rip.now[i - w]}
			if y < shared.rip.h - 1 && shared.rip.wet[i + w] {b = shared.rip.now[i + w]}
			shared.rip.next[i] = (2 * u - shared.rip.before[i] + RIPPLE_SPEED2 * (l + r_ + a + b - 4 * u)) * RIPPLE_DAMPING
		}
	}
	for y in lo ..< hi {
		copy(shared.rip.before[y * w:][:w], shared.rip.now[y * w:][:w])
		copy(shared.rip.now[y * w:][:w], shared.rip.next[y * w:][:w])
	}
	shared.rip.awake -= 1
	if shared.rip.awake == 0 {
		for &v in shared.rip.now {v = 0}
		for &v in shared.rip.before {v = 0}
	}
	rl.UpdateTexture(shared.rip.tex, raw_data(shared.rip.now))
}

// What the shader reads: the heights, and a cell in texture coordinates.
ripple_texture :: proc() -> rl.Texture2D {
	return shared.rip.tex
}

ripple_cell :: proc() -> [2]f32 {
	return {1 / f32(max(shared.rip.w, 1)), 1 / f32(max(shared.rip.h, 1))}
}
