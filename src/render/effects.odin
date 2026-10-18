package render

import "dr:sim"

// What the presentation keeps of its own from step to step, outside
// sim.State: particles, motion-blur ghosts and the notice banner. One set
// per window, with its Renderer; the game, its shots and tools/clips each
// keep one.
Effects :: struct {
	particles: Particles,
	blurs:     Blurs,
	notices:   Notices,
}

effects_init :: proc(e: ^Effects) {
	particles_init(&e.particles)
	blurs_init(&e.blurs)
}

effects_destroy :: proc(e: ^Effects) {
	particles_destroy(&e.particles)
	blurs_destroy(&e.blurs)
}

// One sim step's: call once per sim.step, not once per render frame.
effects_step :: proc(e: ^Effects, s: ^sim.State) {
	particles_step(&e.particles, s)
	blurs_step(&e.blurs, s)
	notices_step(&e.notices, s)
}

// Empties them, and the plugins' effect systems, for a new level.
effects_clear :: proc(e: ^Effects) {
	clear(&e.particles.live)
	effect_systems_clear()
	clear(&e.blurs.live)
	e.notices = {}
}
