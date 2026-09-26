package game

// The Mods page of Preferences: every plugin this build registered
// (sim/plugins.odin), each with a switch. Turning a mod on turns on what it
// needs; turning one off turns off what needs it, so the saved set is
// always one that can run. New content, built from Text_Buttons like the
// Extras page.

import "core:fmt"
import "core:strings"

import rl "vendor:raylib"

import "dr:sim"

@(private = "file") MODS_TITLE_Y :: 34
@(private = "file") MODS_ROW0_Y :: 70
@(private = "file") MODS_ROW :: 48
@(private = "file") MODS_ROWS_SHOWN :: 7
@(private = "file") MODS_LABEL_X :: 70
@(private = "file") MODS_VALUE_X :: 540
@(private = "file") MODS_SCROLL_X :: 600
@(private = "file") MODS_NOTE_Y :: 410
@(private = "file") MODS_BACK_Y :: 436

Mods_Page :: struct {
	scroll:  Scroll_Rows,
	toggles: [sim.MAX_PLUGINS + 1]Text_Button,
	back:    Text_Button,
}

// Every registered plugin, CORE's empty slot aside.
@(private = "file")
mods_listed :: proc() -> []sim.Plugin {
	return sim.registered_plugins()[1:]
}

@(private = "file")
mods_row_y :: proc(m: ^Mods_Page, row: int) -> (f32, bool) {
	shown := row - m.scroll.first
	return MODS_ROW0_Y + f32(shown) * MODS_ROW, shown >= 0 && shown < MODS_ROWS_SHOWN
}

@(private = "file")
mods_page_layout :: proc(r: ^Renderer, m: ^Mods_Page, ps: ^Prefs_State) {
	for _, row in mods_listed() {
		if y, shown := mods_row_y(m, row); shown {
			text_button_relabel(r, &m.toggles[row + 1], row + 1 in ps.saved.mods ? "ON" : "OFF", MODS_VALUE_X, y)
		}
	}
	text_button_relabel(r, &m.back, "BACK", SCREEN_W / 2, MODS_BACK_Y)
}

// Returns true when the page is left (Back or Escape).
mods_page_update :: proc(r: ^Renderer, m: ^Mods_Page, ps: ^Prefs_State) -> (leave: bool) {
	scroll_rows_update(&m.scroll, len(mods_listed()), MODS_ROWS_SHOWN)
	mods_page_layout(r, m, ps)
	mouse := menu_mouse_pos()
	dt := rl.GetFrameTime()
	for _, row in mods_listed() {
		if _, shown := mods_row_y(m, row); shown && text_button_update(r, &m.toggles[row + 1], mouse, dt) {
			prefs_mod_toggle(ps, sim.Plugin_ID(row + 1))
		}
	}
	return text_button_update(r, &m.back, mouse, dt) || rl.IsKeyPressed(.ESCAPE)
}

mods_page_draw :: proc(r: ^Renderer, m: ^Mods_Page, ps: ^Prefs_State) {
	mods_page_layout(r, m, ps)
	menu_draw_background(r, "back")
	white := rl.Color{255, 255, 255, 255}
	dim := rl.Color{190, 190, 190, 255}
	header := rl.Color{HIGH_SCORES_HEADER_RGB[0], HIGH_SCORES_HEADER_RGB[1], HIGH_SCORES_HEADER_RGB[2], 255}
	classic := prefs_classic(ps)

	menu_draw_text(r, "MODS", SCREEN_W / 2, MODS_TITLE_Y, header, .Centre)
	listed := mods_listed()
	for p, row in listed {
		y, shown := mods_row_y(m, row)
		if !shown {
			continue
		}
		menu_draw_text(r, p.label, MODS_LABEL_X, i32(y) + 5, classic ? dim : white)
		menu_draw_text(r, mods_detail(p), MODS_LABEL_X, i32(y) + 24, dim)
		text_button_draw(r, &m.toggles[row + 1])
	}
	scroll_rows_draw(&m.scroll, len(listed), MODS_ROWS_SHOWN, MODS_SCROLL_X, MODS_ROW0_Y, MODS_ROWS_SHOWN * MODS_ROW - 20)
	note := classic ? "CLASSIC MODE IS ON: MODS ARE OFF UNTIL IT IS TURNED OFF" : "WHAT DEIMOS ROSE ADDS -- NONE APPLY IN CLASSIC MODE"
	menu_draw_text(r, note, SCREEN_W / 2, MODS_NOTE_Y, dim, .Centre)
	text_button_draw(r, &m.back)
}

// A mod's description, and what it needs, in the menu font's capitals.
@(private = "file")
mods_detail :: proc(p: sim.Plugin) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, strings.to_upper(p.description, context.temp_allocator))
	for dep, i in p.deps {
		label := dep
		if id, ok := sim.plugin_find(dep); ok {
			label = sim.registered_plugins()[id].label
		}
		fmt.sbprintf(&sb, "%s%s", i == 0 ? " -- NEEDS " : ", ", label)
	}
	return strings.to_string(sb)
}
