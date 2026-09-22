package game

// Phase 7: shared building blocks for the faithfully-recreated menu screens
// (Main Menu, and later Level Select/Credits/High Scores) -- a full-screen
// background loader, and a sprite-plate button with hover/click detection.
// See docs/phase-7-faithful-menus.md and D21 for the trace this is built
// from.

import rl "vendor:raylib"

import "dr:sim"

MEBU :: sim.Res_ID{'m', 'e', 'b', 'u'} // button plate, not hovered
MEBH :: sim.Res_ID{'m', 'e', 'b', 'h'} // button plate, hovered/"hilited"

// Interface_Btn_HiliteDelay (perm float 0x?? -- 10 ticks at the original's
// fixed 30Hz). Converted to seconds since menu screens run at render rate,
// not sim rate, so a hover held across a slow or fast monitor still takes
// the same real time to register.
HILITE_DELAY :: 10.0 / 30.0

// A hoverable, clickable rectangle in logical (640x480) space -- the mouse
// position menu_mouse_pos returns is in the same space, so hit-testing needs
// no further scaling.
@(private = "file")
update_hover_click :: proc(rect: rl.Rectangle, hover_time: ^f32, mouse: rl.Vector2, dt: f32) -> (clicked: bool) {
	if rl.CheckCollisionPointRec(mouse, rect) {
		hover_time^ += dt
		return rl.IsMouseButtonPressed(.LEFT)
	}
	hover_time^ = 0
	return false
}

// A baked-text button: one shared frame index into both MEBU (normal) and
// MEBH (hilited) -- FUN_004277e0 confirmed the label is part of the plate
// art, not drawn separately, so there is no font rendering here at all.
Menu_Button :: struct {
	frame:      i32,
	rect:       rl.Rectangle, // logical space; sized to the plate frame itself
	hover_time: f32,
}

// Centres a button horizontally at `cy`, sized to its own baked-width plate
// frame (buttons are not a fixed box -- MEBU's frames range from 49 to 145px
// wide across the original's 14 labels).
menu_button_at :: proc(t: ^Textures, frame: i32, cy: f32) -> Menu_Button {
	_, src, ok := frame_rect(t, MEBU, frame)
	if !ok {
		return {}
	}
	return Menu_Button{frame = frame, rect = {(SCREEN_W - src.width) / 2, cy, src.width, src.height}}
}

menu_button_update :: proc(b: ^Menu_Button, mouse: rl.Vector2, dt: f32) -> (clicked: bool) {
	return update_hover_click(b.rect, &b.hover_time, mouse, dt)
}

// Draws the hilited plate once hover has been held past HILITE_DELAY, the
// normal one otherwise -- both frames are drawn at the normal frame's own
// position, since MEBH's frames run a few pixels larger (a highlight border
// growing outward, not a resized button).
menu_button_draw :: proc(r: ^Renderer, b: ^Menu_Button) {
	plate := b.hover_time >= HILITE_DELAY ? MEBH : MEBU
	tex, src, ok := frame_rect(&r.textures, plate, b.frame)
	if !ok {
		return
	}
	dst := rl.Rectangle {
		b.rect.x * WINDOW_SCALE, b.rect.y * WINDOW_SCALE,
		b.rect.width * WINDOW_SCALE, b.rect.height * WINDOW_SCALE,
	}
	rl.DrawTexturePro(tex, src, dst, {0, 0}, 0, rl.WHITE)
}

// A plain-text link (the main menu's website/copyright lines, drawn with the
// glyph font rather than a plate) -- same hover/click behaviour as a button.
Text_Link :: struct {
	label:      string,
	rect:       rl.Rectangle,
	hover_time: f32,
}

text_link_at :: proc(r: ^Renderer, label: string, cy: f32) -> Text_Link {
	w := text_width(r, label)
	return Text_Link{label = label, rect = {(SCREEN_W - f32(w)) / 2, cy, f32(w), 10}}
}

text_link_update :: proc(l: ^Text_Link, mouse: rl.Vector2, dt: f32) -> (clicked: bool) {
	return update_hover_click(l.rect, &l.hover_time, mouse, dt)
}

text_link_draw :: proc(r: ^Renderer, l: ^Text_Link) {
	color := l.hover_time > 0 ? rl.Color{255, 255, 255, 255} : rl.Color{190, 190, 190, 255}
	menu_draw_text(r, l.label, i32(l.rect.x), i32(l.rect.y), color)
}

// draw_text (game/text.odin) pushes into the Renderer's layer list, only
// ever flushed by present() -- which menu screens never call, since they
// draw outside build_frame/present entirely (see flow_draw). This draws the
// same glyph plate directly instead, at WINDOW_SCALE, for Title and the
// other menu screens Phase 7 adds.
menu_draw_text :: proc(r: ^Renderer, s: string, x, y: i32, color := rl.Color{255, 255, 255, 255}, align := Align.Left, spacing: i32 = 0) {
	x := x
	switch align {
	case .Centre:
		x -= text_width(r, s, spacing) / 2
	case .Right:
		x -= text_width(r, s, spacing)
	case .Left:
	}
	for i in 0 ..< len(s) {
		tex, src, ok := frame_rect(&r.textures, FONT, glyph_of(s[i]))
		if !ok {
			continue
		}
		dst := rl.Rectangle {
			f32(x * WINDOW_SCALE), f32(y * WINDOW_SCALE),
			src.width * WINDOW_SCALE, src.height * WINDOW_SCALE,
		}
		rl.DrawTexturePro(tex, src, dst, {0, 0}, 0, color)
		x += i32(src.width) + spacing
	}
}

// Mouse position in logical (640x480) space -- the window itself is
// WINDOW_SCALE'd, but every menu layout constant here is in logical pixels.
menu_mouse_pos :: proc() -> rl.Vector2 {
	p := rl.GetMousePosition()
	return {p.x / WINDOW_SCALE, p.y / WINDOW_SCALE}
}

// A full-screen im16 background at logical (640x480) size, scaled to the
// window -- Main Menu, Credits and High Scores all reuse "back".
menu_draw_background :: proc(r: ^Renderer, id: string) {
	tex, ok := menu_image(&r.textures, id)
	if !ok {
		return
	}
	dst := rl.Rectangle{0, 0, SCREEN_W * WINDOW_SCALE, SCREEN_H * WINDOW_SCALE}
	rl.DrawTexturePro(tex, {0, 0, f32(tex.width), f32(tex.height)}, dst, {0, 0}, 0, rl.WHITE)
}
