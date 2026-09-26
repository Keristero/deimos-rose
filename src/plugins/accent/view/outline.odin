package accent_view

// Self Outline: the local player's ship ringed in its accent, a render
// system of the Accent Color plugin's, drawn only while the plugin is on.

import "base:runtime"

import "dr:plugins/accent"
import "dr:render"
import "dr:sim"

@(init)
register_outline :: proc "contextless" () {
	context = runtime.default_context()
	// Under the local player's ship, so ahead of it.
	render.render_system_register({name = "outline", before = OUTLINE_BEFORE, plugin = accent.ID, run = outline_render})
}

@(private = "file", rodata)
OUTLINE_BEFORE := []string{"players"}

// The ship's own shape in its accent, one pixel out in each of the eight
// directions: Self Outline, for the local player.
@(private = "file")
outline_render :: proc(r: ^render.Renderer, s: ^sim.State, f: ^render.Frame) {
	for p, k in sim.players_of(s) {
		ac := r.accents[k]
		if !ac.outline || !p.active || p.state != .Playing {
			continue
		}
		place, ok := render.object_place(r, p.obj, render.ship_before(f, k))
		if !ok {
			continue
		}
		alpha := u8(clamp(p.obj.visibility, 0, 100) * 255 / 100)
		for d in ([8][2]f32{{-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1}}) {
			dst := place.dst
			dst.x += d.x
			dst.y += d.y
			render.push_item(r, place.layer, render.Item {
				texture = place.texture, src = place.src, dst = dst, tint = {255, 255, 255, alpha},
				effect = .Silhouette, hue = ac.hue, sat = render.ACCENT_SATURATION,
			})
		}
	}
}
