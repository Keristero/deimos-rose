package new_weapons_view

// The Discharge Beam's shots (plugins/new_weapons/beam.odin), drawn: new
// content, with no original to match. The simulation keeps its recent beams
// in the session's Beam_Log; each step, this takes those still fading, as
// an effect system (render/render_systems.odin). Reading the log rather than
// the step's effect events is what shows the other player's beams in
// netplay: they fire on steps a rollback replays (beam.odin). Each run of a
// beam is a line from where it set out to where it stopped (straight up
// from the gun, or from target to target for a chain), drawn additively
// over the air enemies and under the ships: a wide glow fading to its
// edges, the beam's own width in red, and a bright core, all narrowing as
// they fade. A charged beam is wider and brighter and lasts longer.
//
// Provisional: every size and colour here was picked by eye.


import rl "vendor:raylib"
import "vendor:raylib/rlgl"

import "dr:plugins/new_weapons"
import "dr:render"
import "dr:sim"

Beam_Fx :: struct {
	using ev: new_weapons.Beam_Event,
	age:      i32, // steps since it fired
}

// The beams on screen. Presentation keeps one set, as the game has one
// screen; cleared with the rest of the in-play effects.
@(private = "file")
live: [dynamic]Beam_Fx

// The layer the air enemies are drawn in; the ships are above.
@(private = "file")
AIR_LAYER :: 8

register :: proc() {
	render.effect_system_register({
		name   = "beams",
		plugin = new_weapons.ID,
		step   = beams_step,
		draw   = beams_draw,
		layer  = AIR_LAYER,
		clear  = beams_clear,
	})
}

@(init)
register_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/new_weapons/view register", register)
}

@(private = "file")
beams_clear :: proc() {
	clear(&live)
}

@(private = "file") BEAM_LIFE :: 6 // steps a pulse takes to fade
@(private = "file") BEAM_CHARGED_LIFE :: 12
@(private = "file") BEAM_GLOW :: rl.Color{255, 32, 16, 255}
@(private = "file") BEAM_BODY :: rl.Color{255, 64, 32, 255}
@(private = "file") BEAM_CORE :: rl.Color{255, 232, 216, 255}

@(private = "file")
beam_life :: #force_inline proc(b: ^Beam_Fx) -> i32 {
	return b.charged ? BEAM_CHARGED_LIFE : BEAM_LIFE
}

// One sim step: the logged beams of this level still fading, their age
// counted from the step they fired on, so one that a rollback replayed
// shows as far through its fade as it would have.
beams_step :: proc(r: ^render.Renderer, s: ^sim.State, p: ^render.Particles) {
	clear(&live)
	log := new_weapons.beam_log_of(s)
	if log == nil {
		return
	}
	time := sim.single(s, sim.Clock).time
	level := sim.single(s, sim.Level_Info).played
	for k in 0 ..< i32(new_weapons.MAX_RECENT_BEAMS) {
		ev := log.events[(log.next + k) % new_weapons.MAX_RECENT_BEAMS]
		if ev.width <= 0 || ev.level != level {
			continue
		}
		b := Beam_Fx{ev = ev, age = time - 1 - ev.time}
		if b.age >= 0 && b.age < beam_life(&b) {
			append(&live, b)
		}
	}
}

// `t` is how far the frame is from the last step to this one, so a beam
// fades smoothly at high refresh rates.
beams_draw :: proc(r: ^render.Renderer, scale, side, t: f32) {
	if len(live) == 0 {
		return
	}
	rl.BeginBlendMode(.ADDITIVE)
	for &b in live {
		life := f32(beam_life(&b))
		k := 1 - max(f32(b.age) - (1 - t), 0) / life // 1 as it fires .. 0 gone
		if k <= 0 {
			continue
		}
		from, to := screen(b.from, scale, side), screen({b.to.x, max(b.to.y, -8)}, scale, side)
		width := b.width * (0.4 + 0.6 * k) * scale
		bright: f32 = b.charged ? 1.2 : 1
		// The glow falls off from the middle to nothing at either edge.
		run(from, to, width * 3, BEAM_GLOW, 0.6 * k * bright, true)
		run(from, to, width, BEAM_BODY, 0.85 * k * bright, false)
		run(from, to, max(width * 0.4, scale), BEAM_CORE, k, false)
		if b.to.y > 0 {
			// Where it stopped: a flare the width of the glow.
			rl.DrawCircleV(to, width * 1.5, with_alpha(BEAM_GLOW, 0.6 * k))
			rl.DrawCircleV(to, width * 0.6, with_alpha(BEAM_CORE, k))
		}
	}
	rl.EndBlendMode()
}

@(private = "file")
screen :: #force_inline proc(v: sim.Vec, scale, side: f32) -> rl.Vector2 {
	return {(render.VIEW_X + v.x - side) * scale, v.y * scale}
}

@(private = "file")
with_alpha :: proc(c: rl.Color, a: f32) -> rl.Color {
	col := c
	col.a = u8(clamp(a, 0, 1) * 255)
	return col
}

// A band `w` wide along the run from `a` to `b`, in window pixels: solid,
// or with `fade` falling off from the middle to nothing at its edges. Drawn
// as triangles whose corners carry the colour, which a beam at any angle
// needs and raylib's rectangles, square to the screen, cannot give.
@(private = "file")
run :: proc(a, b: rl.Vector2, w: f32, c: rl.Color, alpha: f32, fade: bool) {
	d := b - a
	l := rl.Vector2Length(d)
	if l <= 0 {
		return
	}
	n := rl.Vector2{-d.y, d.x} / l * (w / 2)
	mid, edge := with_alpha(c, alpha), with_alpha(c, fade ? 0 : alpha)
	rlgl.Begin(rlgl.TRIANGLES)
	quad(a - n, b - n, b, a, edge, edge, mid, mid)
	quad(a, b, b + n, a + n, mid, mid, edge, edge)
	rlgl.End()
}

// Two triangles over the corners in order, each wound the way raylib draws
// a face (counter-clockwise on screen, y down).
@(private = "file")
quad :: proc(p0, p1, p2, p3: rl.Vector2, c0, c1, c2, c3: rl.Color) {
	tri :: proc(a, b, c: rl.Vector2, ca, cb, cc: rl.Color) {
		b, c, cb, cc := b, c, cb, cc
		if (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) > 0 {
			b, c, cb, cc = c, b, cc, cb
		}
		vertex :: proc(v: rl.Vector2, col: rl.Color) {
			rlgl.Color4ub(col.r, col.g, col.b, col.a)
			rlgl.Vertex2f(v.x, v.y)
		}
		vertex(a, ca)
		vertex(b, cb)
		vertex(c, cc)
	}
	tri(p0, p1, p2, c0, c1, c2)
	tri(p0, p2, p3, c0, c2, c3)
}
