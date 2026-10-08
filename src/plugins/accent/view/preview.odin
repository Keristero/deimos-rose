package accent_view

import "core:os"
import "core:strconv"

import rl "vendor:raylib"

import "dr:plugins/accent"
import "dr:prefs"
import "dr:render"
import "dr:sim"
import "dr:ui"

// Accent Color's preview on the Extras page: both players' ships as a
// local game draws them -- each in its own hue, with Self Outline on
// player 1's, the ship this machine's player flies. Off to the right of
// the rows rather than beside one, since several of them change it.

@(private = "file") PREVIEW_SHIPS :: [2]sim.Res_ID{{'p', 'l', '1', 'b'}, {'p', 'l', '2', 'b'}}
@(private = "file") PREVIEW_X :: 540 // centre of the pair
@(private = "file") PREVIEW_Y :: 150
@(private = "file") PREVIEW_GAP :: 70

register_preview :: proc() {
	ui.settings_preview_register({plugin = accent.ID, draw = preview_draw})
	// The Extras page with a colour and Self Outline on, so both previews
	// show what they do. DR_SHOT_HUE picks the hue: 63 should match
	// player 2's gold.
	ui.menu_shot_register({name = "preferences_extras", plugin = accent.ID, screen = "extras", setup = preview_shot_setup})
}

@(init)
register_preview_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/accent/view register_preview", register_preview)
}

@(private = "file")
preview_shot_setup :: proc(p: ^prefs.Prefs) {
	p.settings[HUE_P1] = 30
	if hue, ok := strconv.parse_int(os.get_env("DR_SHOT_HUE", context.temp_allocator)); ok {
		p.settings[HUE_P1] = prefs.hue_wrap(hue)
	}
	p.settings[SELF_OUTLINE] = 1
}

@(private = "file")
preview_draw :: proc(r: ^render.Renderer, values: ^[prefs.MAX_SETTINGS]int, live: bool) {
	dim := rl.Color{190, 190, 190, 255}
	hues := [2]prefs.Setting_ID{HUE_P1, HUE_P2}
	for id, i in PREVIEW_SHIPS {
		px := PREVIEW_X + (f32(i) - 0.5) * PREVIEW_GAP
		outline := i == 0 && live && values[SELF_OUTLINE] != 0
		preview_ship(r, id, f32(values[hues[i]]), outline, live, px, PREVIEW_Y)
		ui.menu_draw_text(r, i == 0 ? "P1" : "P2", i32(px), PREVIEW_Y + 26, dim, .Centre)
	}
}

// The ship as it would be drawn in play, centred on (x, y) in menu
// coordinates: through the same draw_item the game uses, so the preview
// cannot drift from the real thing. Its trim is coloured only while the
// plugin is in effect.
@(private = "file")
preview_ship :: proc(r: ^render.Renderer, id: sim.Res_ID, hue: f32, outline, trimmed: bool, x, y: f32) {
	tex, src, ok := render.frame_rect(&r.textures, id, 0)
	if !ok {
		return
	}
	s := f32(render.WINDOW_SCALE)
	dst := rl.Rectangle{(x - src.width / 2) * s, (y - src.height / 2) * s, src.width * s, src.height * s}
	white := rl.Color{255, 255, 255, 255}
	if outline {
		for d in ([8][2]f32{{-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1}}) {
			o := dst
			o.x += d.x * s
			o.y += d.y * s
			render.draw_item(r, {texture = tex, src = src, tint = white, effect = .Silhouette, hue = hue, sat = render.ACCENT_SATURATION}, o)
		}
	}
	render.draw_item(r, {texture = tex, src = src, tint = white}, dst)
	if trim, tok := render.ship_trim(&r.textures, id); trimmed && tok {
		render.draw_item(r, {texture = trim, src = src, tint = white, effect = .Recolour, hue = hue, sat = render.TRIM_SATURATION, shine = render.TRIM_SHINE}, dst)
	}
}
