package game

// The bursts an entity leaves when it is hit or destroyed (G_Particle_NewGroup
// / _Process / _Draw). The one gameplay RNG draw per particle -- which of five
// shades it takes -- is made in sim/destroy.odin, where oracle:diff can count
// it, and arrives here in the event. Everything else is presentation and is
// ported as the original does it:
//
// - Directions come from two 100-entry tables built once at start-up
//   (FUN_004300b0): unit vectors from the play field's centre towards a random
//   point on it. Table A scales each by 1, 0.85, 0.7 or 0.55 at random; table
//   B, used by the "ice" sizes (laci/meci/smci/tici), leaves them unit length,
//   so those bursts are a ring. A global index walks each table, wrapping at
//   99, from a random start.
// - Speed is the direction times 5 for med/larg/meci/laci and 3 for the rest.
// - Each step: ground groups ride the vertical scroll, velocity *= 0.96
//   (Particle_Gravity), move, die off the field, and fade += 1
//   (Particle_BlendAmountRate_Long) until 32.
// - The five shades are the colour scaled by 1 - 0.12i
//   (Particle_ColorVariationAdjust); each particle's fringe is its shade
//   scaled by 0.6 (Particle_FringeColorAdjust), all in 16-bit channels
//   truncated to 5 bits by U_Pixel16_RGBToPixel16.
// - Each is drawn as a 7x7 blended stamp with its top left at the particle
//   (G_Particle_Draw): a solid centre in the shade, a darker fringe ring and
//   corners, each ring more transparent, and the whole fading as `fade` rises.

import "core:math"
import "core:math/rand"

import rl "vendor:raylib"

import "dr:sim"

Particle :: struct {
	loc:    sim.Vec,
	prev:   sim.Vec, // loc a step ago, for high refresh rate interpolation
	vel:    sim.Vec,
	shade:  [3]u8, // 5-bit channels
	fringe: [3]u8,
	fade:   i32, // 0 opaque .. 32 gone
	ground: bool, // rides the vertical scroll, like G_Particle_Process
}

PARTICLE_DIRECTIONS :: 100

Particles :: struct {
	live:       [dynamic]Particle,
	directions: [2][PARTICLE_DIRECTIONS]sim.Vec, // A (varied speed), B (ice)
	next:       [2]int,
}

@(private = "file") PF_GRAVITY :: 0x90
@(private = "file") PF_COLOR_VARIATION :: 0x91
@(private = "file") PF_FRINGE :: 0x92
@(private = "file") PF_FADE_RATE :: 0x94

particles_init :: proc(p: ^Particles) {
	p.live = make([dynamic]Particle, 0, 256)
	// FUN_004300b0, over the 416x480 play field. The original reads its size
	// from perm floats 0x36/0x37, which are fixed.
	w, h := i32(PLAY_W), i32(PLAY_H)
	speeds := [4]f32{1, 0.85, 0.7, 0.55}
	for i in 0 ..< PARTICLE_DIRECTIONS {
		d := sim.Vec{f32(w) / 2 - f32(rand.int31_max(w + 1)), f32(h) / 2 - f32(rand.int31_max(h + 1))}
		n := math.sqrt(f32(i32(d.x * d.x + d.y * d.y)))
		if n == 0 {
			n = 1
		}
		d /= n
		p.directions[1][i] = d
		p.directions[0][i] = d * speeds[rand.int31_max(4)]
	}
	p.next = {int(rand.int31_max(PARTICLE_DIRECTIONS)), int(rand.int31_max(PARTICLE_DIRECTIONS))}
}

particles_destroy :: proc(p: ^Particles) {
	delete(p.live)
}

// One sim step: new bursts from this step's events, then G_Particle_Process
// over every live particle. Call once per sim.step, not once per render
// frame, so particle motion stays tied to game time.
particles_step :: proc(p: ^Particles, s: ^sim.State) {
	pf := &s.defs.perm_floats
	for &ev in s.particles.events[:s.particles.count] {
		spawn_burst(p, &ev, pf)
	}
	gravity := pf[PF_GRAVITY]
	rate := max(sim.trunc_i32(pf[PF_FADE_RATE]), 1)
	scroll := f32(s.bgnd.scrolled)
	n := 0
	for pt in p.live {
		pt := pt
		pt.prev = pt.loc
		if pt.ground {
			pt.loc.y += scroll
			pt.prev.y += scroll
		}
		pt.vel *= gravity
		pt.loc += pt.vel
		if pt.loc.x < -32 || pt.loc.x + 7 > PLAY_W + 32 || pt.loc.y < 0 || pt.loc.y + 7 > PLAY_H {
			continue
		}
		if pt.fade >= 32 {
			continue
		}
		pt.fade = min(pt.fade + rate, 32)
		p.live[n] = pt
		n += 1
	}
	resize(&p.live, n)
}

@(private = "file")
spawn_burst :: proc(p: ^Particles, ev: ^sim.Particle_Event, pf: ^[sim.PERM_FLOATS]f32) {
	n := sim.particle_count(ev.size)
	if n == 0 {
		return
	}
	ice, fast: bool
	switch ev.size {
	case sim.res_id("laci"), sim.res_id("meci"), sim.res_id("smci"), sim.res_id("tici"):
		ice = true
	}
	switch ev.size {
	case sim.res_id("med "), sim.res_id("larg"), sim.res_id("laci"), sim.res_id("meci"):
		fast = true
	}

	// The five shades and their fringes, in 16-bit channels as NewGroup
	// keeps them, truncated back to 5 bits for the stamp.
	shades, fringes: [5][3]u8
	for i in 0 ..< 5 {
		k := 1 - f32(i) * pf[PF_COLOR_VARIATION]
		for c in 0 ..< 3 {
			v := sim.trunc_i32(f32(ev.color[c] >> 3) / 32 * 65535)
			v = sim.trunc_i32(f32(v) * k)
			shades[i][c] = u8(v >> 11)
			fringes[i][c] = u8(sim.trunc_i32(f32(v) * pf[PF_FRINGE]) >> 11)
		}
	}

	table := ice ? 1 : 0
	speed: f32 = fast ? 5 : 3
	for i in 0 ..< int(n) {
		d := p.directions[table][p.next[table]]
		p.next[table] = (p.next[table] + 1) % (PARTICLE_DIRECTIONS - 1)
		k := ev.shades[i]
		append(&p.live, Particle {
			loc    = ev.loc,
			prev   = ev.loc,
			vel    = d * speed,
			shade  = shades[k],
			fringe = fringes[k],
			ground = ev.ground,
		})
	}
}

// G_Particle_Draw's stamp: which of five blend weights each pixel takes, and
// whether it is in the shade (the centre cross) or the fringe.
@(private = "file")
STAMP := [7]string {
	"aabbbaa",
	"abcccba",
	"bcDdDcb",
	"bcdedcb",
	"bcDdDcb",
	"abcccba",
	"aabbbaa",
}

// `t` is the renderer's interpolation fraction, 1 when off; `side` is the
// view's sideways scroll, which the original subtracts from x.
particles_draw :: proc(p: ^Particles, scale: f32, side: f32, t: f32 = 1) {
	for pt in p.live {
		loc := pt.loc
		if t < 1 {
			loc = {interp(pt.prev.x, pt.loc.x, t), interp(pt.prev.y, pt.loc.y, t)}
		}
		x := sim.trunc_i32(loc.x - side)
		y := sim.trunc_i32(loc.y)
		if x < 0 || f32(x) + 7 >= PLAY_W || y < 0 || f32(y) + 7 >= PLAY_H {
			continue
		}
		f := pt.fade
		// The destination's weight out of 32; the colour gets the rest.
		weight := [5]i32 {
			min(f + 22, 31), // a: corners
			min(f + 10, 31), // b: outer ring
			min(f + 6, 31), // c: inner ring
			f, // d: around the centre
			f > 6 ? f - 7 : f, // e: the centre
		}
		shade := expand5(pt.shade)
		fringe := expand5(pt.fringe)
		for row, j in STAMP {
			for ch, i in row {
				w: i32
				c := fringe
				switch ch {
				case 'a': w = weight[0]
				case 'b': w = weight[1]
				case 'c': w = weight[2]
				case 'D': w = weight[3]
				case 'd': w = weight[3]; c = shade
				case 'e': w = weight[4]; c = shade
				}
				c.a = u8((32 - w) * 255 / 32)
				rl.DrawRectangleRec({(VIEW_X + f32(x + i32(i))) * scale, f32(y + i32(j)) * scale, scale, scale}, c)
			}
		}
	}
}

@(private = "file")
expand5 :: proc(c: [3]u8) -> rl.Color {
	return {c[0] << 3 | c[0] >> 2, c[1] << 3 | c[1] >> 2, c[2] << 3 | c[2] >> 2, 255}
}
