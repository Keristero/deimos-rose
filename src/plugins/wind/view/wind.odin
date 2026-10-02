package wind_view

// The wind, on the particles: each step, every live particle is nudged by
// the level's wind (data.Level_Wind, from the editor) times the WIND
// STRENGTH setting. A level without wind is untouched.
//
// Provisional: the direction is read as degrees clockwise from up (dx =
// sin a, dy = -cos a), and a strength of 1 as a pixel a step; the editor
// has no wind control yet, so no shipped level has any.

import "core:math"

import "dr:data"
import "dr:plugins/wind"
import "dr:prefs"
import "dr:render"
import "dr:sim"

STRENGTH: prefs.Setting_ID

register :: proc() {
	STRENGTH = prefs.setting_register({plugin = wind.ID, key = "wind_strength", label = "WIND STRENGTH", kind = .Percent, default = 100})
	render.effect_system_register({name = "wind", plugin = wind.ID, step = step})
}

@(init)
register_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/wind/view register", register)
}

@(private = "file")
step :: proc(r: ^render.Renderer, s: ^sim.State, p: ^render.Particles) {
	level := sim.level_def(s)
	media := data.assets_level_media(&r.textures.assets, level.campaign, level.id)
	if media == nil || media.wind.strength == 0 {
		return
	}
	a := math.to_radians(media.wind.direction_degrees)
	push := media.wind.strength * f32(r.setting[STRENGTH]) / 100
	d := sim.Vec{math.sin(a) * push, -math.cos(a) * push}
	for &pt in p.live {
		pt.loc += d
		pt.prev += d
	}
}
