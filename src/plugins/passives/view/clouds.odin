package passives_view

// The corrosive clouds (plugins/passives/clouds.odin), drawn: new content,
// with no original to match. The simulation keeps them in the session's
// Clouds; each step, this takes those of the level still there, as an effect
// system, so a rollback's clouds show as they are. Each is a soft green haze
// the size of the cloud with a few puffs turning slowly inside it, drawn
// over the air enemies and under the ships. It swells in as it forms and
// thins as it goes.
//
// Provisional: every size, colour and time here was picked by eye.

import "core:math"

import rl "vendor:raylib"

import "dr:plugins/passives"
import "dr:render"
import "dr:sim"

@(private = "file")
Cloud_Fx :: struct {
	using cloud: passives.Cloud,
	time:        i32, // the step it is drawn at
}

// The clouds on screen, as the beams keep theirs (plugins/new_weapons/view).
@(private = "file")
live: [dynamic]Cloud_Fx

// The layer the air enemies are drawn in; the ships are above.
@(private = "file")
AIR_LAYER :: 8

@(private = "file") CLOUD_SWELL :: 6 // steps a cloud takes to form
@(private = "file") CLOUD_THIN :: 20 // steps it takes to go
@(private = "file") CLOUD_PUFFS :: 4
@(private = "file") CLOUD_HAZE :: rl.Color{168, 208, 32, 255}
@(private = "file") CLOUD_PUFF :: rl.Color{216, 236, 72, 255}

register_clouds_view :: proc() {
	render.effect_system_register({
		name   = "clouds",
		plugin = passives.ID,
		step   = clouds_step,
		draw   = clouds_draw,
		layer  = AIR_LAYER,
		clear  = clouds_clear,
	})
}

@(private = "file")
clouds_clear :: proc() {
	clear(&live)
}

@(private = "file")
clouds_step :: proc(r: ^render.Renderer, s: ^sim.State, p: ^render.Particles) {
	clear(&live)
	time := sim.single(s, sim.Clock).time
	level := sim.single(s, sim.Level_Info).played
	for &c in passives.clouds_of(s).clouds {
		if passives.cloud_live(&c, time, level) {
			append(&live, Cloud_Fx{cloud = c, time = time})
		}
	}
}

// `t` is how far the frame is from the last step to this one, so a cloud
// swells, turns and thins smoothly at high refresh rates.
@(private = "file")
clouds_draw :: proc(r: ^render.Renderer, scale, side, t: f32) {
	if len(live) == 0 {
		return
	}
	for &c in live {
		now := f32(c.time) + t
		k := min((now - f32(c.start)) / CLOUD_SWELL, (f32(c.until) - now) / CLOUD_THIN, 1)
		if k <= 0 {
			continue
		}
		at := rl.Vector2{(render.VIEW_X + c.loc.x - side) * scale, c.loc.y * scale}
		radius := f32(passives.CLOUD_RADIUS) * scale * (0.6 + 0.4 * k)
		rl.DrawCircleGradient(at, radius * 1.2, fade(CLOUD_HAZE, 0.55 * k), fade(CLOUD_HAZE, 0))
		// The puffs turn about the middle, each cloud from its own start.
		for i in 0 ..< CLOUD_PUFFS {
			a := f32(i) * 2 * math.PI / CLOUD_PUFFS + (now - f32(c.start)) * 0.05 + f32(c.start)
			off := rl.Vector2{math.cos(a), math.sin(a)} * radius * 0.45
			rl.DrawCircleGradient(at + off, radius * 0.5, fade(CLOUD_PUFF, 0.45 * k), fade(CLOUD_PUFF, 0))
		}
	}
}

@(private = "file")
fade :: proc(c: rl.Color, a: f32) -> rl.Color {
	col := c
	col.a = u8(clamp(a, 0, 1) * 255)
	return col
}
