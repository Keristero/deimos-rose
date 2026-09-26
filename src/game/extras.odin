package game

// Mods and their settings: features the original never had. Each is a
// plugin (sim/plugins.odin) the player turns on from the Mods page
// (game/menu_mods.odin); the settings the mods register (prefs/settings.odin)
// are on the Extras page below. The rule they all follow is that classic
// mode is the original game -- same look, same behaviour -- so every mod
// reads as off there, whatever is saved. Code that implements one asks
// prefs_mod_on, setting_on and setting_value and nothing else.

import rl "vendor:raylib"

import "dr:plugins/accent"
import accent_view "dr:plugins/accent/view"
import "dr:plugins/extra_prefs"
import "dr:plugins/fps_unlock"
import "dr:prefs"
import "dr:sim"

// The mods in effect: the saved ones whose dependencies are all on, and
// none in classic mode. -highrefreshrate turns on 30FPS Unlock for the
// run.
prefs_mods :: proc(ps: ^Prefs_State) -> sim.Mods {
	if prefs_classic(ps) {
		return {}
	}
	mods := ps.saved.mods
	if ps.launch.high_refresh_rate {
		mods = sim.mods_with_deps(mods + {int(fps_unlock.ID)})
	}
	return sim.mods_resolve(mods)
}

prefs_mod_on :: proc(ps: ^Prefs_State, id: sim.Plugin_ID) -> bool {
	return int(id) in prefs_mods(ps)
}

// Turns a mod on with its dependencies, or off with its dependants, and
// saves.
prefs_mod_toggle :: proc(ps: ^Prefs_State, id: sim.Plugin_ID) {
	if ps.launch.high_refresh_rate {
		// The menu now shows and controls what is live.
		ps.saved.mods = sim.mods_with_deps(ps.saved.mods + {int(fps_unlock.ID)})
		ps.launch.high_refresh_rate = false
	}
	prefs.mod_toggle(&ps.saved.mods, id)
	prefs_state_save(ps)
}

// Switches a mod on or off, leaving it as it is when it already is.
prefs_mod_set :: proc(ps: ^Prefs_State, id: sim.Plugin_ID, on: bool) {
	if (int(id) in ps.saved.mods) != on {
		prefs_mod_toggle(ps, id)
	}
}

// Whether a toggle setting is on and in effect: its mod is on.
setting_on :: proc(ps: ^Prefs_State, id: prefs.Setting_ID) -> bool {
	return prefs_mod_on(ps, prefs.registered_settings()[id].plugin) && ps.saved.settings[id] != 0
}

// The saved value, whether or not it is in effect (a hue for the lobby to
// send, say).
setting_value :: proc(ps: ^Prefs_State, id: prefs.Setting_ID) -> int {
	return ps.saved.settings[id]
}

setting_set :: proc(ps: ^Prefs_State, id: prefs.Setting_ID, v: int) {
	ps.saved.settings[id] = prefs.setting_clean(id, v)
	prefs_state_save(ps)
}

// A strip of every hue: dragged with the mouse, or nudged with Left/Right
// when `keys` (which type nothing into a name being entered beside it).
// Menu coordinates. Returns whether the hue changed.
HUE_SLIDER_H :: 8
@(private = "file") HUE_KEY_STEP :: 5

hue_slider_update :: proc(hue: ^int, rect: rl.Rectangle, keys: bool) -> bool {
	before := hue^
	if keys && (rl.IsKeyPressed(.LEFT) || rl.IsKeyPressedRepeat(.LEFT)) {
		hue^ = prefs.hue_wrap(hue^ - HUE_KEY_STEP)
	}
	if keys && (rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressedRepeat(.RIGHT)) {
		hue^ = prefs.hue_wrap(hue^ + HUE_KEY_STEP)
	}
	if rl.IsMouseButtonDown(.LEFT) {
		m := menu_mouse_pos()
		grab := rl.Rectangle{rect.x - 4, rect.y - 6, rect.width + 8, rect.height + 12}
		if rl.CheckCollisionPointRec(m, grab) {
			hue^ = min(int(clamp((m.x - rect.x) / rect.width, 0, 1) * 360), 359)
		}
	}
	return hue^ != before
}

hue_slider_draw :: proc(hue: int, rect: rl.Rectangle, dim := false) {
	s := f32(WINDOW_SCALE)
	for i in 0 ..< i32(rect.width) {
		c := rl.ColorFromHSV(f32(i) * 360 / rect.width, ACCENT_SATURATION, dim ? 0.45 : 1)
		rl.DrawRectangle((i32(rect.x) + i) * WINDOW_SCALE, i32(rect.y) * WINDOW_SCALE, WINDOW_SCALE, i32(rect.height) * WINDOW_SCALE, c)
	}
	x := (rect.x + f32(hue) * rect.width / 360) * s
	rl.DrawRectangleLinesEx({x - 3, (rect.y - 3) * s, 7, (rect.height + 6) * s}, 2, rl.WHITE)
}

// A column of rows too many for the screen: the mouse wheel and Page
// Up/Down move it a row at a time. `first` is the first row shown.
Scroll_Rows :: struct {
	first: int,
}

scroll_rows_update :: proc(sc: ^Scroll_Rows, rows, shown: int) {
	step := 0
	if wheel := rl.GetMouseWheelMove(); wheel != 0 {
		step = wheel > 0 ? -1 : 1
	}
	if rl.IsKeyPressed(.PAGE_UP) {
		step = -shown
	}
	if rl.IsKeyPressed(.PAGE_DOWN) {
		step = shown
	}
	sc.first = clamp(sc.first + step, 0, max(rows - shown, 0))
}

// A bar beside the rows, when they do not all fit, showing where the
// shown ones are among them. Menu coordinates.
scroll_rows_draw :: proc(sc: ^Scroll_Rows, rows, shown: int, x, top, height: f32) {
	if rows <= shown {
		return
	}
	s := f32(WINDOW_SCALE)
	track := rl.Color{110, 110, 110, 255}
	rl.DrawRectangleLinesEx({x * s, top * s, 4 * s, height * s}, 1, track)
	thumb_h := height * f32(shown) / f32(rows)
	thumb_y := top + height * f32(sc.first) / f32(rows)
	rl.DrawRectangleRec({x * s, thumb_y * s, 4 * s, thumb_h * s}, rl.Color{190, 190, 190, 255})
}

// The Extras page of Preferences: the Extra Preferences mod's, listing the
// settings of every mod that is on.

@(private = "file") EXTRAS_TITLE_Y :: 34
@(private = "file") EXTRAS_ROW0_Y :: 90
@(private = "file") EXTRAS_ROW :: 44
@(private = "file") EXTRAS_ROWS_SHOWN :: 7
@(private = "file") EXTRAS_LABEL_X :: 110
@(private = "file") EXTRAS_VALUE_X :: 350 // centre of a toggle; a slider spans either side
@(private = "file") EXTRAS_SLIDER_W :: 150
@(private = "file") EXTRAS_SCROLL_X :: 440
@(private = "file") EXTRAS_BACK_Y :: 436
@(private = "file") EXTRAS_NOTE_Y :: 404

// Accent Color's preview: both players' ships as a local game draws them
// -- each in its own hue, with Self Outline on player 1's, the ship this
// machine's player flies. Off to the right of the rows rather than beside
// one, since several of them change it.
@(private = "file") PREVIEW_SHIPS :: [2]sim.Res_ID{{'p', 'l', '1', 'b'}, {'p', 'l', '2', 'b'}}
@(private = "file") PREVIEW_X :: 540 // centre of the pair
@(private = "file") PREVIEW_Y :: 150
@(private = "file") PREVIEW_GAP :: 70

Extras_Page :: struct {
	scroll:  Scroll_Rows,
	toggles: [prefs.MAX_SETTINGS]Text_Button,
	back:    Text_Button,
}

// The settings listed: those of the saved mods, dimmed but still there in
// classic mode, so the page shows what classic mode switched off.
@(private = "file")
extras_listed :: proc(ps: ^Prefs_State, out: ^[prefs.MAX_SETTINGS]prefs.Setting_ID) -> []prefs.Setting_ID {
	mods := sim.mods_resolve(ps.saved.mods)
	n := 0
	for s, id in prefs.registered_settings() {
		if int(s.plugin) in mods {
			out[n] = prefs.Setting_ID(id)
			n += 1
		}
	}
	return out[:n]
}

// Where the listed setting at `row` sits on the page; false when it is
// scrolled out of sight.
@(private = "file")
extras_row_y :: proc(x: ^Extras_Page, row: int) -> (f32, bool) {
	shown := row - x.scroll.first
	return EXTRAS_ROW0_Y + f32(shown) * EXTRAS_ROW, shown >= 0 && shown < EXTRAS_ROWS_SHOWN
}

@(private = "file")
extras_slider_rect :: proc(y: f32) -> rl.Rectangle {
	return {EXTRAS_VALUE_X - EXTRAS_SLIDER_W / 2, y + 6, EXTRAS_SLIDER_W, HUE_SLIDER_H}
}

// Toggles show their live value, so they are re-laid each frame.
@(private = "file")
extras_page_layout :: proc(r: ^Renderer, x: ^Extras_Page, ps: ^Prefs_State, listed: []prefs.Setting_ID) {
	settings := prefs.registered_settings()
	for id, row in listed {
		y, shown := extras_row_y(x, row)
		if shown && settings[id].kind == .Toggle {
			text_button_relabel(r, &x.toggles[id], ps.saved.settings[id] != 0 ? "ON" : "OFF", EXTRAS_VALUE_X, y)
		}
	}
	text_button_relabel(r, &x.back, "BACK", SCREEN_W / 2, EXTRAS_BACK_Y)
}

// Returns true when the page is left (Back or Escape).
extras_page_update :: proc(r: ^Renderer, x: ^Extras_Page, ps: ^Prefs_State) -> (leave: bool) {
	buf: [prefs.MAX_SETTINGS]prefs.Setting_ID
	listed := extras_listed(ps, &buf)
	scroll_rows_update(&x.scroll, len(listed), EXTRAS_ROWS_SHOWN)
	extras_page_layout(r, x, ps, listed)
	mouse := menu_mouse_pos()
	dt := rl.GetFrameTime()
	settings := prefs.registered_settings()
	for id, row in listed {
		y, shown := extras_row_y(x, row)
		if !shown {
			continue
		}
		switch settings[id].kind {
		case .Toggle:
			if text_button_update(r, &x.toggles[id], mouse, dt) {
				setting_set(ps, id, 1 - ps.saved.settings[id])
			}
		case .Hue:
			hue := ps.saved.settings[id]
			if hue_slider_update(&hue, extras_slider_rect(y), true) {
				ps.saved.settings[id] = hue // saved once the drag ends, not every frame of it
			}
			if rl.IsMouseButtonReleased(.LEFT) || rl.IsKeyReleased(.LEFT) || rl.IsKeyReleased(.RIGHT) {
				prefs_state_save(ps)
			}
		}
	}
	return text_button_update(r, &x.back, mouse, dt) || rl.IsKeyPressed(.ESCAPE)
}

extras_page_draw :: proc(r: ^Renderer, x: ^Extras_Page, ps: ^Prefs_State) {
	buf: [prefs.MAX_SETTINGS]prefs.Setting_ID
	listed := extras_listed(ps, &buf)
	extras_page_layout(r, x, ps, listed)
	menu_draw_background(r, "back")
	white := rl.Color{255, 255, 255, 255}
	dim := rl.Color{190, 190, 190, 255}
	header := rl.Color{HIGH_SCORES_HEADER_RGB[0], HIGH_SCORES_HEADER_RGB[1], HIGH_SCORES_HEADER_RGB[2], 255}
	classic := prefs_classic(ps)

	menu_draw_text(r, "EXTRAS", SCREEN_W / 2, EXTRAS_TITLE_Y, header, .Centre)
	settings := prefs.registered_settings()
	for id, row in listed {
		y, shown := extras_row_y(x, row)
		if !shown {
			continue
		}
		menu_draw_text(r, settings[id].label, EXTRAS_LABEL_X, i32(y) + 5, classic ? dim : white)
		switch settings[id].kind {
		case .Toggle:
			text_button_draw(r, &x.toggles[id])
		case .Hue:
			hue_slider_draw(ps.saved.settings[id], extras_slider_rect(y), classic)
		}
	}
	scroll_rows_draw(&x.scroll, len(listed), EXTRAS_ROWS_SHOWN, EXTRAS_SCROLL_X, EXTRAS_ROW0_Y, EXTRAS_ROWS_SHOWN * EXTRAS_ROW - 20)
	if int(accent.ID) in sim.mods_resolve(ps.saved.mods) {
		hues := [2]prefs.Setting_ID{accent_view.HUE_P1, accent_view.HUE_P2}
		for id, i in PREVIEW_SHIPS {
			px := PREVIEW_X + (f32(i) - 0.5) * PREVIEW_GAP
			preview_ship(r, ps, id, hues[i], i == 0, px, PREVIEW_Y)
			menu_draw_text(r, i == 0 ? "P1" : "P2", i32(px), PREVIEW_Y + 26, dim, .Centre)
		}
	}
	note: string
	switch {
	case classic:
		note = "CLASSIC MODE IS ON: MODS ARE OFF UNTIL IT IS TURNED OFF"
	case len(listed) == 0:
		note = "NONE OF THE MODS THAT ARE ON HAVE SETTINGS"
	case:
		note = "SETTINGS FOR THE MODS THAT ARE ON -- NONE APPLY IN CLASSIC MODE"
	}
	menu_draw_text(r, note, SCREEN_W / 2, EXTRAS_NOTE_Y, dim, .Centre)
	text_button_draw(r, &x.back)
}

// Whether the Extras page can be opened: its mod is on.
extras_available :: proc(ps: ^Prefs_State) -> bool {
	return int(extra_prefs.ID) in sim.mods_resolve(ps.saved.mods)
}

// The ship as it would be drawn in play, centred on (x, y) in menu
// coordinates: through the same draw_item the game uses, so the preview
// cannot drift from the real thing.
@(private = "file")
preview_ship :: proc(r: ^Renderer, ps: ^Prefs_State, id: sim.Res_ID, hue_id: prefs.Setting_ID, local: bool, x, y: f32) {
	outline := local && setting_on(ps, accent_view.SELF_OUTLINE)
	tex, src, ok := frame_rect(&r.textures, id, 0)
	if !ok {
		return
	}
	s := f32(WINDOW_SCALE)
	dst := rl.Rectangle{(x - src.width / 2) * s, (y - src.height / 2) * s, src.width * s, src.height * s}
	hue := f32(ps.saved.settings[hue_id])
	white := rl.Color{255, 255, 255, 255}
	if outline {
		for d in ([8][2]f32{{-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1}}) {
			o := dst
			o.x += d.x * s
			o.y += d.y * s
			draw_item(r, {texture = tex, src = src, tint = white, effect = .Silhouette, hue = hue, sat = ACCENT_SATURATION}, o)
		}
	}
	draw_item(r, {texture = tex, src = src, tint = white}, dst)
	if trim, tok := ship_trim(&r.textures, id); prefs_mod_on(ps, accent.ID) && tok {
		draw_item(r, {texture = trim, src = src, tint = white, effect = .Recolour, hue = hue, sat = TRIM_SATURATION, shine = TRIM_SHINE}, dst)
	}
}
