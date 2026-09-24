package game

// Extras: settings for features the original never had (prefs.EXTRAS lists
// them). The rule they all follow is that classic mode is the original
// game -- same look, same behaviour -- so every extra reads as off there,
// whatever is saved. Code that implements one asks extra_on/extra_value
// and nothing else; this file owns the gate, the Preferences Extras page
// (one row per EXTRAS entry, built from the table) and the previews some
// rows show beside their control.

import rl "vendor:raylib"

import "dr:prefs"
import "dr:sim"

// Whether an extra is in effect. A hue is in effect whenever extras are.
extra_on :: proc(ps: ^Prefs_State, e: prefs.Extra) -> bool {
	if prefs_classic(ps) {
		return false
	}
	if e == .High_Refresh_Rate && ps.launch.high_refresh_rate {
		return true // -highrefreshrate, for this run only
	}
	return prefs.EXTRAS[e].kind == .Hue || ps.saved.extras[e] != 0
}

// The saved value, whether or not it is in effect (a hue for the lobby to
// send, say).
extra_value :: proc(ps: ^Prefs_State, e: prefs.Extra) -> int {
	return ps.saved.extras[e]
}

extra_set :: proc(ps: ^Prefs_State, e: prefs.Extra, v: int) {
	ps.saved.extras[e] = prefs.extra_clean(e, v)
	if e == .High_Refresh_Rate {
		ps.launch.high_refresh_rate = false // the menu now shows and controls what is live
	}
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

// The Extras page of Preferences.

@(private = "file") EXTRAS_TITLE_Y :: 34
@(private = "file") EXTRAS_ROW0_Y :: 90
@(private = "file") EXTRAS_ROW :: 44
@(private = "file") EXTRAS_LABEL_X :: 110
@(private = "file") EXTRAS_VALUE_X :: 350 // centre of a toggle; a slider spans either side
@(private = "file") EXTRAS_SLIDER_W :: 150
@(private = "file") EXTRAS_BACK_Y :: 436
@(private = "file") EXTRAS_NOTE_Y :: 404

// The preview: both players' ships as they would be drawn in play with
// your accent and outline -- you fly either one in netplay, depending on
// the slot you get. Off to the right of the rows rather than beside one,
// since two of them (hue and outline) change it.
@(private = "file") PREVIEW_SHIPS :: [2]sim.Res_ID{{'p', 'l', '1', 'b'}, {'p', 'l', '2', 'b'}}
@(private = "file") PREVIEW_X :: 540 // centre of the pair
@(private = "file") PREVIEW_Y :: 150
@(private = "file") PREVIEW_GAP :: 70

Extras_Page :: struct {
	toggles: [prefs.Extra]Text_Button,
	back:    Text_Button,
}

@(private = "file")
extras_row_y :: proc(e: prefs.Extra) -> f32 {
	return EXTRAS_ROW0_Y + f32(e) * EXTRAS_ROW
}

@(private = "file")
extras_slider_rect :: proc(e: prefs.Extra) -> rl.Rectangle {
	return {EXTRAS_VALUE_X - EXTRAS_SLIDER_W / 2, extras_row_y(e) + 6, EXTRAS_SLIDER_W, HUE_SLIDER_H}
}

// Toggles show their live value, so they are re-laid each frame.
@(private = "file")
extras_page_layout :: proc(r: ^Renderer, x: ^Extras_Page, ps: ^Prefs_State) {
	for info, e in prefs.EXTRAS {
		if info.kind == .Toggle {
			text_button_relabel(r, &x.toggles[e], ps.saved.extras[e] != 0 ? "ON" : "OFF", EXTRAS_VALUE_X, extras_row_y(e))
		}
	}
	text_button_relabel(r, &x.back, "BACK", SCREEN_W / 2, EXTRAS_BACK_Y)
}

// Returns true when the page is left (Back or Escape).
extras_page_update :: proc(r: ^Renderer, x: ^Extras_Page, ps: ^Prefs_State) -> (leave: bool) {
	extras_page_layout(r, x, ps)
	mouse := menu_mouse_pos()
	dt := rl.GetFrameTime()
	for info, e in prefs.EXTRAS {
		switch info.kind {
		case .Toggle:
			if text_button_update(r, &x.toggles[e], mouse, dt) {
				extra_set(ps, e, 1 - ps.saved.extras[e])
			}
		case .Hue:
			hue := ps.saved.extras[e]
			if hue_slider_update(&hue, extras_slider_rect(e), true) {
				ps.saved.extras[e] = hue // saved once the drag ends, not every frame of it
			}
			if rl.IsMouseButtonReleased(.LEFT) || rl.IsKeyReleased(.LEFT) || rl.IsKeyReleased(.RIGHT) {
				prefs_state_save(ps)
			}
		}
	}
	return text_button_update(r, &x.back, mouse, dt) || rl.IsKeyPressed(.ESCAPE)
}

extras_page_draw :: proc(r: ^Renderer, x: ^Extras_Page, ps: ^Prefs_State) {
	extras_page_layout(r, x, ps)
	menu_draw_background(r, "back")
	white := rl.Color{255, 255, 255, 255}
	dim := rl.Color{190, 190, 190, 255}
	header := rl.Color{HIGH_SCORES_HEADER_RGB[0], HIGH_SCORES_HEADER_RGB[1], HIGH_SCORES_HEADER_RGB[2], 255}
	classic := prefs_classic(ps)

	menu_draw_text(r, "EXTRAS", SCREEN_W / 2, EXTRAS_TITLE_Y, header, .Centre)
	for info, e in prefs.EXTRAS {
		y := extras_row_y(e)
		menu_draw_text(r, info.label, EXTRAS_LABEL_X, i32(y) + 5, classic ? dim : white)
		switch info.kind {
		case .Toggle:
			text_button_draw(r, &x.toggles[e])
		case .Hue:
			hue_slider_draw(ps.saved.extras[e], extras_slider_rect(e), classic)
		}
	}
	for id, i in PREVIEW_SHIPS {
		x := PREVIEW_X + (f32(i) - 0.5) * PREVIEW_GAP
		preview_ship(r, ps, id, x, PREVIEW_Y)
		menu_draw_text(r, i == 0 ? "P1" : "P2", i32(x), PREVIEW_Y + 26, dim, .Centre)
	}
	note := classic ? "CLASSIC MODE IS ON: EXTRAS ARE OFF UNTIL IT IS TURNED OFF" : "FEATURES THE ORIGINAL DID NOT HAVE -- NONE APPLY IN CLASSIC MODE"
	menu_draw_text(r, note, SCREEN_W / 2, EXTRAS_NOTE_Y, dim, .Centre)
	text_button_draw(r, &x.back)
}

// The ship as it would be drawn in play, centred on (x, y) in menu
// coordinates: through the same draw_item the game uses, so the preview
// cannot drift from the real thing.
@(private = "file")
preview_ship :: proc(r: ^Renderer, ps: ^Prefs_State, id: sim.Res_ID, x, y: f32) {
	outline := ps.saved.extras[.Self_Outline] != 0
	tex, src, ok := frame_rect(&r.textures, id, 0)
	if !ok {
		return
	}
	s := f32(WINDOW_SCALE)
	dst := rl.Rectangle{(x - src.width / 2) * s, (y - src.height / 2) * s, src.width * s, src.height * s}
	hue := f32(ps.saved.extras[.Accent_Hue])
	on := !prefs_classic(ps)
	white := rl.Color{255, 255, 255, 255}
	if on && outline {
		for d in ([8][2]f32{{-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1}}) {
			o := dst
			o.x += d.x * s
			o.y += d.y * s
			draw_item(r, {texture = tex, src = src, tint = white, effect = .Silhouette, hue = hue, sat = ACCENT_SATURATION}, o)
		}
	}
	draw_item(r, {texture = tex, src = src, tint = white}, dst)
	if trim, tok := ship_trim(&r.textures, id); on && tok {
		draw_item(r, {texture = trim, src = src, tint = white, effect = .Recolour, hue = hue, sat = TRIM_SATURATION, shine = TRIM_SHINE}, dst)
	}
}
