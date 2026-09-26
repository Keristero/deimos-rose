package game

// The Mods page of Preferences: every plugin this build registered
// (sim/plugins.odin), each with a switch. Turning a mod on turns on what it
// needs; turning one off turns off what needs it, so the saved set is
// always one that can run. New content, built from Text_Buttons like the
// Extras page.

import "core:fmt"
import "core:slice"
import "core:strings"

import rl "vendor:raylib"

import "dr:render"
import "dr:sim"
import "dr:ui"

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
	scroll:  ui.Scroll_Rows,
	toggles: [sim.MAX_PLUGINS]ui.Text_Button, // by row
	back:    ui.Text_Button,
}

// Every registered plugin, in the order the page lists them: each mod
// under the one it needs most deeply, and mods under the same one by
// label, so the list reads as a tree of what needs what. Registration
// order would not do: it is the order packages initialise in, which
// changes whenever the imports between them do.
mods_order :: proc() -> []sim.Plugin_ID {
	@(static) order: Mods_Order
	order.count = 0
	mods_children_add(&order, sim.CORE)
	return order.ids[:order.count]
}

@(private = "file")
Mods_Order :: struct {
	ids:   [sim.MAX_PLUGINS]sim.Plugin_ID,
	count: int,
}

// The mod `id` needs that needs the most itself (CORE for none): the one
// it is listed under.
@(private = "file")
mods_parent :: proc(id: sim.Plugin_ID) -> sim.Plugin_ID {
	parent, best := sim.CORE, -1
	for dep in sim.registered_plugins()[id].deps {
		if d, ok := sim.plugin_find(dep); ok {
			if depth := mods_depth(d); depth > best {
				parent, best = d, depth
			}
		}
	}
	return parent
}

@(private = "file")
mods_depth :: proc(id: sim.Plugin_ID) -> int {
	parent := mods_parent(id)
	return parent == sim.CORE ? 0 : mods_depth(parent) + 1
}

// The mods listed under `parent`, by label, each followed by its own.
@(private = "file")
mods_children_add :: proc(o: ^Mods_Order, parent: sim.Plugin_ID) {
	kids: [sim.MAX_PLUGINS]sim.Plugin_ID
	n := 0
	for i in 1 ..< len(sim.registered_plugins()) {
		if id := sim.Plugin_ID(i); mods_parent(id) == parent {
			kids[n] = id
			n += 1
		}
	}
	slice.sort_by(kids[:n], proc(a, b: sim.Plugin_ID) -> bool {
		return sim.registered_plugins()[a].label < sim.registered_plugins()[b].label
	})
	for id in kids[:n] {
		o.ids[o.count] = id
		o.count += 1
		mods_children_add(o, id)
	}
}

@(private = "file")
mods_row_y :: proc(m: ^Mods_Page, row: int) -> (f32, bool) {
	shown := row - m.scroll.first
	return MODS_ROW0_Y + f32(shown) * MODS_ROW, shown >= 0 && shown < MODS_ROWS_SHOWN
}

@(private = "file")
mods_page_layout :: proc(r: ^render.Renderer, m: ^Mods_Page, ps: ^Prefs_State) {
	for id, row in mods_order() {
		if y, shown := mods_row_y(m, row); shown {
			ui.text_button_relabel(r, &m.toggles[row], int(id) in ps.saved.mods ? "ON" : "OFF", MODS_VALUE_X, y)
		}
	}
	ui.text_button_relabel(r, &m.back, "BACK", render.SCREEN_W / 2, MODS_BACK_Y)
}

// Returns true when the page is left (Back or Escape).
mods_page_update :: proc(r: ^render.Renderer, m: ^Mods_Page, ps: ^Prefs_State) -> (leave: bool) {
	ui.scroll_rows_update(&m.scroll, len(mods_order()), MODS_ROWS_SHOWN)
	mods_page_layout(r, m, ps)
	mouse := ui.menu_mouse_pos()
	dt := rl.GetFrameTime()
	for id, row in mods_order() {
		if _, shown := mods_row_y(m, row); shown && ui.text_button_update(r, &m.toggles[row], mouse, dt) {
			prefs_mod_toggle(ps, id)
		}
	}
	return ui.text_button_update(r, &m.back, mouse, dt) || rl.IsKeyPressed(.ESCAPE)
}

mods_page_draw :: proc(r: ^render.Renderer, m: ^Mods_Page, ps: ^Prefs_State) {
	mods_page_layout(r, m, ps)
	ui.menu_draw_background(r, "back")
	white := rl.Color{255, 255, 255, 255}
	dim := rl.Color{190, 190, 190, 255}
	header := rl.Color{ui.HIGH_SCORES_HEADER_RGB[0], ui.HIGH_SCORES_HEADER_RGB[1], ui.HIGH_SCORES_HEADER_RGB[2], 255}
	classic := prefs_classic(ps)

	ui.menu_draw_text(r, "MODS", render.SCREEN_W / 2, MODS_TITLE_Y, header, .Centre)
	listed := mods_order()
	for id, row in listed {
		y, shown := mods_row_y(m, row)
		if !shown {
			continue
		}
		p := sim.registered_plugins()[id]
		ui.menu_draw_text(r, p.label, MODS_LABEL_X, i32(y) + 5, classic ? dim : white)
		ui.menu_draw_text(r, mods_detail(p), MODS_LABEL_X, i32(y) + 24, dim)
		ui.text_button_draw(r, &m.toggles[row])
	}
	ui.scroll_rows_draw(&m.scroll, len(listed), MODS_ROWS_SHOWN, MODS_SCROLL_X, MODS_ROW0_Y, MODS_ROWS_SHOWN * MODS_ROW - 20)
	note := classic ? "CLASSIC MODE IS ON: MODS ARE OFF UNTIL IT IS TURNED OFF" : "WHAT DEIMOS ROSE ADDS -- NONE APPLY IN CLASSIC MODE"
	ui.menu_draw_text(r, note, render.SCREEN_W / 2, MODS_NOTE_Y, dim, .Centre)
	ui.text_button_draw(r, &m.back)
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
