package game

// The Discharge Beam's shots (sim/beam.odin), drawn: new content, with no
// original to match. The sim hands over each step's beams in `s.beams`; this
// keeps them for the few steps they fade over, in the Particles list since
// they live and die with the other in-play effects. Each is a line straight
// up from the gun to where it stopped, drawn additively: a wide glow fading to its edges, the
// beam's own width in red, and a bright core, all narrowing as they fade. A
// charged beam is wider and brighter and lasts longer.
//
// Provisional: every size and colour here was picked by eye.

import rl "vendor:raylib"

import "dr:sim"

Beam_Fx :: struct {
	using ev: sim.Beam_Event,
	age:      i32, // steps since it fired
}

@(private = "file") BEAM_LIFE :: 6 // steps a pulse takes to fade
@(private = "file") BEAM_CHARGED_LIFE :: 12
@(private = "file") BEAM_GLOW :: rl.Color{248, 40, 24, 255}
@(private = "file") BEAM_BODY :: rl.Color{248, 72, 48, 255}
@(private = "file") BEAM_CORE :: rl.Color{255, 224, 208, 255}

@(private = "file")
beam_life :: #force_inline proc(b: ^Beam_Fx) -> i32 {
	return b.charged ? BEAM_CHARGED_LIFE : BEAM_LIFE
}

// One sim step: age the live beams, drop the spent, take this step's.
beams_step :: proc(p: ^Particles, s: ^sim.State) {
	n := 0
	for &b in p.beams {
		b.age += 1
		if b.age < beam_life(&b) {
			p.beams[n] = b
			n += 1
		}
	}
	resize(&p.beams, n)
	for ev in s.beams.events[:s.beams.count] {
		append(&p.beams, Beam_Fx{ev = ev})
	}
}

// `t` is how far the frame is from the last step to this one, so a beam
// fades smoothly at high refresh rates.
beams_draw :: proc(p: ^Particles, scale: f32, side: f32, t: f32 = 1) {
	if len(p.beams) == 0 {
		return
	}
	rl.BeginBlendMode(.ADDITIVE)
	for &b in p.beams {
		life := f32(beam_life(&b))
		k := 1 - max(f32(b.age) - (1 - t), 0) / life // 1 as it fires .. 0 gone
		if k <= 0 {
			continue
		}
		x := b.from.x - side
		top := max(b.to_y, -8)
		bottom := b.from.y
		width := b.width * (0.4 + 0.6 * k)
		bright: f32 = b.charged ? 1 : 0.8
		band :: proc(x, top, bottom, w: f32, c: rl.Color, a: f32, scale: f32) {
			col := c
			col.a = u8(clamp(a, 0, 1) * 255)
			rl.DrawRectangleRec({(VIEW_X + x - w / 2) * scale, top * scale, w * scale, (bottom - top) * scale}, col)
		}
		// The glow falls off from the middle to nothing at either edge.
		glow :: proc(x, top, bottom, w: f32, c: rl.Color, a: f32, scale: f32) {
			mid, edge := c, c
			mid.a, edge.a = u8(clamp(a, 0, 1) * 255), 0
			h := (bottom - top) * scale
			rl.DrawRectangleGradientEx({(VIEW_X + x - w / 2) * scale, top * scale, w / 2 * scale, h}, edge, edge, mid, mid)
			rl.DrawRectangleGradientEx({(VIEW_X + x) * scale, top * scale, w / 2 * scale, h}, mid, mid, edge, edge)
		}
		glow(x, top, bottom, width * 3, BEAM_GLOW, 0.45 * k * bright, scale)
		band(x, top, bottom, width, BEAM_BODY, 0.7 * k * bright, scale)
		band(x, top, bottom, max(width * 0.35, 1), BEAM_CORE, k, scale)
		if b.to_y > 0 {
			// Where it stopped: a flare the width of the glow.
			rl.DrawCircleV({(VIEW_X + x) * scale, b.to_y * scale}, width * 1.5 * scale, {BEAM_GLOW.r, BEAM_GLOW.g, BEAM_GLOW.b, u8(0.6 * k * 255)})
			rl.DrawCircleV({(VIEW_X + x) * scale, b.to_y * scale}, width * 0.6 * scale, {BEAM_CORE.r, BEAM_CORE.g, BEAM_CORE.b, u8(k * 255)})
		}
	}
	rl.EndBlendMode()
}
