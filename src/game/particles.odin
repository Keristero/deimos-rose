package game

// The burst of coloured squares an entity leaves when it is destroyed
// (G_Particle_NewGroup / _Process / _Draw). The gameplay RNG draws are made
// in sim/destroy.odin, because their count has to match the original for
// oracle:diff; what those draws actually decided (per-particle direction,
// exact fade curve) has no effect on anything else, so rather than port
// G_Particle_Process's direction table and two-phase fade ramp byte for
// byte, this spawns a simpler burst that reads the same: particles fan out
// from the event's point, decelerate, and fade over a short lifetime.

import "core:math"
import "core:math/rand"

import rl "vendor:raylib"

import "dr:sim"

Particle :: struct {
	loc:      sim.Vec,
	prev:     sim.Vec, // loc a step ago, for high refresh rate interpolation
	vel:      sim.Vec,
	color:    rl.Color,
	life:     f32,
	max_life: f32,
	ground:   bool, // rides the vertical scroll, like G_Particle_Process
}

Particles :: struct {
	live: [dynamic]Particle,
}

particles_init :: proc(p: ^Particles) {
	p.live = make([dynamic]Particle, 0, 256)
}

particles_destroy :: proc(p: ^Particles) {
	delete(p.live)
}

// One sim step: new bursts from this step's events, then age and cull every
// live particle. Call once per sim.step, not once per render frame, so
// particle motion stays tied to game time rather than wall-clock framerate.
particles_step :: proc(p: ^Particles, s: ^sim.State) {
	for ev in s.particles.events[:s.particles.count] {
		spawn_burst(p, ev)
	}
	scroll := f32(s.bgnd.scrolled)
	n := 0
	for pt in p.live {
		pt := pt
		pt.prev = pt.loc
		if pt.ground {
			pt.loc.y += scroll
		}
		pt.vel *= 0.92
		pt.loc += pt.vel
		pt.life -= 1
		if pt.life > 0 {
			p.live[n] = pt
			n += 1
		}
	}
	resize(&p.live, n)
}

@(private = "file")
spawn_burst :: proc(p: ^Particles, ev: sim.Particle_Event) {
	n := sim.particle_count(ev.size)
	if n == 0 {
		return
	}
	bright := rl.Color{ev.color.r, ev.color.g, ev.color.b, 255}
	dark := rl.Color{ev.color.r / 2, ev.color.g / 2, ev.color.b / 2, 255}
	for i in 0 ..< n {
		angle := f32(i) / f32(n) * math.TAU + rand.float32_range(-0.4, 0.4)
		speed := rand.float32_range(1.0, 3.0)
		life := rand.float32_range(14, 26)
		append(&p.live, Particle {
			loc      = ev.loc,
			prev     = ev.loc,
			vel      = {math.cos(angle) * speed, math.sin(angle) * speed},
			color    = i % 2 == 0 ? bright : dark,
			life     = life,
			max_life = life,
			ground   = ev.ground,
		})
	}
}

// G_Particle_Draw: a small filled square per particle, fading with age.
// `t` is the renderer's interpolation fraction, 1 when off.
particles_draw :: proc(p: ^Particles, scale: f32, t: f32 = 1) {
	for pt in p.live {
		alpha := clamp(pt.life / pt.max_life, 0, 1)
		c := pt.color
		c.a = u8(alpha * 255)
		size: f32 = 2 * scale
		loc := pt.loc
		if t < 1 {
			loc = {interp(pt.prev.x, pt.loc.x, t), interp(pt.prev.y, pt.loc.y, t)}
		}
		rl.DrawRectangleV(
			{(loc.x + VIEW_X) * scale - size / 2, loc.y * scale - size / 2},
			{size, size},
			c,
		)
	}
}
