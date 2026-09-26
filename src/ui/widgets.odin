package ui

// Widgets for the pages the original never had: a hue slider and a
// scrolling list of rows.

import rl "vendor:raylib"

import "dr:prefs"
import "dr:render"

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
	s := f32(render.WINDOW_SCALE)
	for i in 0 ..< i32(rect.width) {
		c := rl.ColorFromHSV(f32(i) * 360 / rect.width, render.ACCENT_SATURATION, dim ? 0.45 : 1)
		rl.DrawRectangle((i32(rect.x) + i) * render.WINDOW_SCALE, i32(rect.y) * render.WINDOW_SCALE, render.WINDOW_SCALE, i32(rect.height) * render.WINDOW_SCALE, c)
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
	s := f32(render.WINDOW_SCALE)
	track := rl.Color{110, 110, 110, 255}
	rl.DrawRectangleLinesEx({x * s, top * s, 4 * s, height * s}, 1, track)
	thumb_h := height * f32(shown) / f32(rows)
	thumb_y := top + height * f32(sc.first) / f32(rows)
	rl.DrawRectangleRec({x * s, thumb_y * s, 4 * s, thumb_h * s}, rl.Color{190, 190, 190, 255})
}

// The Extras page of Preferences: the Extra Preferences mod's, listing the
// settings of every mod that is on.
