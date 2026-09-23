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

// A button hilites the moment the pointer is over it. This once waited
// Interface_Btn_HiliteDelay (perm float 0x3d, 10 ticks) first, reading the
// name as "delay before hiliting" -- but the original hilites at once
// (observed by the project owner), so that reading was wrong. What 0x3d
// does is untraced (no decomp corpus in reach when this was changed); a
// minimum gap between rollover sounds is one candidate. Unused until then.

// InterfaceMenuButtonRollover (perm sound 0xb, idli/gaso.json) as the
// pointer arrives on a button, and InterfaceClick (perm sound 2) when one
// is pressed. Provisional on the click: ButtonClick (perm sound 0, "clic")
// is the other candidate, but Credits and High Scores both close on
// InterfaceClick and Score Entry uses ButtonClick for typed characters, so
// InterfaceClick is the better-evidenced guess for a menu press.
MENU_ROLLOVER_SOUND :: sim.Res_ID{'m', 'b', 'r', 'o'}
MENU_CLICK_SOUND :: sim.Res_ID{'i', 'n', 'c', 'l'}

// A hoverable, clickable rectangle in logical (640x480) space -- the mouse
// position menu_mouse_pos returns is in the same space, so hit-testing needs
// no further scaling.
// Package-visible (not file-private): Level Select's own hit-testing
// (game/menu_level_select.odin) reuses this too, since its three preview
// slots need the same hover-accumulate/edge-triggered-click behaviour as a
// Menu_Button, just at fixed rects rather than a centred plate frame.
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

menu_button_update :: proc(r: ^Renderer, b: ^Menu_Button, mouse: rl.Vector2, dt: f32) -> (clicked: bool) {
	return update_hover_click_sounds(r, b.rect, &b.hover_time, mouse, dt)
}

// update_hover_click, plus the menu's rollover and click sounds. hover_time
// is at least dt while hovered, so "was zero, now not" is the arrival.
update_hover_click_sounds :: proc(r: ^Renderer, rect: rl.Rectangle, hover_time: ^f32, mouse: rl.Vector2, dt: f32) -> (clicked: bool) {
	was_hovered := hover_time^ > 0
	clicked = update_hover_click(rect, hover_time, mouse, max(dt, 1e-6))
	if !was_hovered && hover_time^ > 0 {
		menu_play_sound(r, MENU_ROLLOVER_SOUND)
	}
	if clicked {
		menu_play_sound(r, MENU_CLICK_SOUND)
	}
	return
}

// Draws the hilited plate while hovered, the normal one otherwise -- both
// frames are drawn at the normal frame's own position, since MEBH's frames
// run a few pixels larger (a highlight border growing outward, not a
// resized button).
menu_button_draw :: proc(r: ^Renderer, b: ^Menu_Button) {
	plate := b.hover_time > 0 ? MEBH : MEBU
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

// A clickable button drawn as centred text rather than a plate frame --
// Menu_Button only knows the original's baked MEBU/MEBH labels, so screens
// with no original art of their own (Phase 7 stage 6's netplay lobby/
// settings screen, which has no original counterpart to trace) use this
// instead. Same hover/click behaviour as Menu_Button, same colour-shift-on-
// hover language as Text_Link, so it reads as part of the same menu family
// without claiming to be a pixel-accurate recreation of anything.
Text_Button :: struct {
	label:      string,
	rect:       rl.Rectangle,
	hover_time: f32,
}

@(private = "file") TEXT_BUTTON_PAD_X :: 14
@(private = "file") TEXT_BUTTON_HEIGHT :: 20

text_button_at :: proc(r: ^Renderer, label: string, cy: f32) -> Text_Button {
	return text_button_at_x(r, label, SCREEN_W / 2, cy)
}

// Same as text_button_at, but centred on a given x rather than the screen's
// midpoint -- for a row of more than one button sharing a y (Phase 8 stage
// 2's level-select prev/next arrows either side of the level name).
text_button_at_x :: proc(r: ^Renderer, label: string, cx, cy: f32) -> Text_Button {
	w := text_width(r, label)
	full := f32(w) + TEXT_BUTTON_PAD_X * 2
	return Text_Button{label = label, rect = {cx - full / 2, cy, full, TEXT_BUTTON_HEIGHT}}
}

// Re-centres a Text_Button on a new label, keeping its hover state -- for
// buttons whose label is a live value (Preferences' key names and volumes).
text_button_relabel :: proc(r: ^Renderer, b: ^Text_Button, label: string, cx, cy: f32) {
	hover := b.hover_time
	b^ = text_button_at_x(r, label, cx, cy)
	b.hover_time = hover
}

text_button_update :: proc(r: ^Renderer, b: ^Text_Button, mouse: rl.Vector2, dt: f32) -> (clicked: bool) {
	return update_hover_click_sounds(r, b.rect, &b.hover_time, mouse, dt)
}

text_button_draw :: proc(r: ^Renderer, b: ^Text_Button, enabled := true) {
	color: rl.Color
	switch {
	case !enabled:
		color = rl.Color{110, 110, 110, 255}
	case b.hover_time > 0:
		color = rl.Color{255, 255, 255, 255}
	case:
		color = rl.Color{190, 190, 190, 255}
	}
	rl.DrawRectangleLinesEx(
		{b.rect.x * WINDOW_SCALE, b.rect.y * WINDOW_SCALE, b.rect.width * WINDOW_SCALE, b.rect.height * WINDOW_SCALE},
		1, color,
	)
	menu_draw_text(r, b.label, i32(b.rect.x + TEXT_BUTTON_PAD_X), i32(b.rect.y + 5), color)
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

// Plays a UI sound directly, bypassing sim's event queue (sound.odin's
// sounds_step) -- a menu screen has no sim.State backing it to route sound
// events through. Resets volume/pitch to the plain defaults each time, since
// a voice alias may have been left at whatever a gameplay sound event last
// set it to (sound.odin varies both per sim.Sound_Event).
menu_play_sound :: proc(r: ^Renderer, id: sim.Res_ID) {
	clip, ok := &r.textures.sounds[id]
	if !ok {
		return
	}
	v := clip.next
	clip.next = (clip.next + 1) % SOUND_VOICES
	snd := clip.voices[v]
	rl.SetSoundVolume(snd, r.textures.sfx_volume)
	rl.SetSoundPitch(snd, 1.0)
	rl.PlaySound(snd)
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
