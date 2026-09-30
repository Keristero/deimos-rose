package editor

// The Units tab: the palette, the selected unit's settings, the mouse and
// keys on the map, and the units drawn over the views.

import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"

import rl "vendor:raylib"

import "dr:sim"

// The palette list's height, at most and at least.
PALETTE_HEIGHT_MAX :: 260
PALETTE_HEIGHT_MIN :: 100
// Room kept under the palette for the selected unit's settings.
SELECTED_HEIGHT :: 300

GROUND_COLOUR :: rl.Color{255, 170, 60, 255}
AIR_COLOUR :: rl.Color{110, 200, 255, 255}
SELECTED_COLOUR :: rl.Color{255, 220, 90, 255}

// The palette entries the layer filter shows, as indices into defs.units.
palette_shown :: proc(e: ^Editor, allocator := context.temp_allocator) -> []int {
	shown := make([dynamic]int, allocator)
	for i in e.units.palette {
		if layer_shown(e, e.units.defs.units[i].is_ground_based) {
			append(&shown, i)
		}
	}
	return shown[:]
}

// defs.units' index of the palette's unit `id`, or -1.
palette_find :: proc(e: ^Editor, id: string) -> int {
	for i in e.units.palette {
		if string(e.units.defs.units[i].id[:]) == id {
			return i
		}
	}
	return -1
}

units_panel :: proc(e: ^Editor, x: f32, y: ^f32, w: f32, bottom: f32) {
	heading(x, y, w, "Units")
	rl.GuiToggleGroup({x, y^, (w - 2 * 2) / 3, 20}, "Both;Ground;Air", &e.layers)
	y^ += ROW
	if len(e.units.palette) == 0 {
		help(x, y, w, {"No units: the assets tree is missing", "(mise run assets:all)."})
		return
	}

	shown := palette_shown(e)
	sb := strings.builder_make(context.temp_allocator)
	active := c.int(-1)
	for i, k in shown {
		u := &e.units.defs.units[i]
		if k > 0 {
			strings.write_byte(&sb, ';')
		}
		// raygui splits the list on ';'.
		name, _ := strings.replace_all(u.name != "" ? u.name : "?", ";", ",", context.temp_allocator)
		fmt.sbprintf(&sb, "%s  %s", string(u.id[:]), name)
		if i == e.palette_unit {
			active = c.int(k)
		}
	}
	list_h := clamp(bottom - y^ - SELECTED_HEIGHT, PALETTE_HEIGHT_MIN, PALETTE_HEIGHT_MAX)
	was := active
	rl.GuiListView({x, y^, w, list_h}, strings.to_cstring(&sb), &e.palette_scroll, &active)
	if active != was {
		e.palette_unit = active >= 0 && int(active) < len(shown) ? shown[active] : -1
	}
	y^ += list_h + 4

	// The unit to place, as it will look.
	if e.palette_unit >= 0 {
		u := &e.units.defs.units[e.palette_unit]
		box := rl.Rectangle{x, y^, 40, 40}
		rl.DrawRectangleRec(box, {24, 26, 30, 255})
		sprite, frame := unit_look(u, 0)
		unit_draw(e, sprite, frame, {box.x + 20, box.y + 20}, min(1, 40 / unit_largest(e, sprite, frame)), rl.WHITE)
		rl.GuiLabel({x + 48, y^, w - 48, 20}, fmt.ctprintf("%s  %s", string(u.id[:]), u.name))
		rl.GuiLabel({x + 48, y^ + 18, w - 48, 20}, u.is_ground_based ? "On the ground" : "In the air")
		y^ += 44
	}

	helpers_panel(e, x, y, w)

	if e.selected < 0 || e.selected >= len(e.project.placements) {
		y^ += 4
		help(x, y, w, {"Pick a unit, then click the map to place it.", "Click a unit to select it; drag to move it.", "Right-click a unit to pick its kind.", "Q, E: turn it, where the level sets its heading", "(Shift: by 1 degree).", "Delete: remove it.  Esc: select none.", "U: show or hide the units."})
		return
	}
	pl := &e.project.placements[e.selected]
	u := catalogue_unit(&e.units, pl.unit)
	heading(x, y, w, "Selected")
	rl.GuiLabel({x, y^, w, 20}, fmt.ctprintf("%s  %s", pl.unit, u != nil ? u.name : "(not in this build)"))
	y^ += 20
	at := placement_point(&e.units, pl^)
	rl.GuiLabel({x, y^, w, 20}, fmt.ctprintf("At %.0f, %.0f, %s", at.x, at.y, placement_ground(&e.units, pl^) ? "on the ground" : "in the air"))
	y^ += ROW

	if placement_turns(e, pl^) {
		turn := f32(pl.heading_degrees)
		slider(x, y, w, "Heading", &turn, 0, 359, "%.0f deg")
		if h := int(turn + 0.5); h != pl.heading_degrees {
			placements_changing(e)
			pl.heading_degrees = h
		}
	}
	flag :: proc(e: ^Editor, x: f32, y: ^f32, label: cstring, value: ^bool) {
		v := value^
		rl.GuiCheckBox({x, y^, 20, 20}, label, &v)
		if v != value^ {
			placements_changing(e)
			value^ = v
		}
		y^ += ROW
	}
	// Offered where the unit offers it, or where the level already has it.
	if u != nil && u.allow_stationary_option_in_placement_editor || pl.is_stationary {
		flag(e, x, y, "Stationary", &pl.is_stationary)
	}
	flag(e, x, y, "Terrain effects", &pl.terrain_effects)
	if rl.GuiButton({x, y^, 96, 20}, "Delete (Del)") {
		editor_placement_delete(e, e.selected)
		return
	}
	y^ += ROW + 4

	// When and how it spawns.
	lines := make([dynamic]cstring, context.temp_allocator)
	append(&lines, fmt.ctprintf("Spawns when the screen's top reaches row %d,", pl.y + SPAWN_AHEAD))
	append(&lines, fmt.ctprintf("%d rows before it comes into view.", SPAWN_AHEAD))
	if u != nil {
		if u.num_in_group_max > 1 {
			append(&lines, fmt.ctprintf("A group of %d to %d.", u.num_in_group_min, max(u.num_in_group_min, u.num_in_group_max)))
		}
		if u.appears_percent != 100 {
			append(&lines, fmt.ctprintf("Each appears %d%% of the time.", u.appears_percent))
		}
		if !u.initial_heading_set_in_editor {
			append(&lines, "It takes its own heading, not the level's.")
		}
		if spawns := unit_spawns(u); spawns != "" {
			append(&lines, fmt.ctprintf("Spawns %s.", spawns))
		}
	}
	help(x, y, w, lines[:])
}

// The units a unit's first state spawns, by id: "mis1, smk2".
@(private = "file")
unit_spawns :: proc(u: ^sim.Unit) -> string {
	if len(u.states) == 0 {
		return ""
	}
	sb := strings.builder_make(context.temp_allocator)
	seen := make(map[sim.Res_ID]bool, context.temp_allocator)
	for &set in u.states[0].spawn_sets {
		if set.spawn == sim.NONE || seen[set.spawn] {
			continue
		}
		seen[set.spawn] = true
		if len(seen) > 1 {
			strings.write_string(&sb, ", ")
		}
		strings.write_string(&sb, strings.trim_right_space(string(set.spawn[:])))
	}
	return strings.to_string(sb)
}

// The mouse on the map in the Units tab.
units_input :: proc(e: ^Editor) {
	v := &e.view
	e.hovered = v.over_map ? placement_pick(e, v.cursor) : -1
	if rl.IsMouseButtonPressed(.LEFT) && v.over_map {
		switch {
		case e.hovered >= 0:
			e.selected = e.hovered
			e.dragging_unit = true
			e.drag_offset = placement_point(&e.units, e.project.placements[e.selected]) - v.cursor
		case e.palette_unit >= 0:
			editor_place(e, e.palette_unit, v.cursor)
			e.dragging_unit, e.drag_offset = true, {}
		case:
			e.selected = -1
		}
	} else if rl.IsMouseButtonDown(.LEFT) && e.dragging_unit && e.selected >= 0 {
		// The point is kept on the map, where the spawn can find it.
		p := &e.project
		to := v.cursor + e.drag_offset
		to = {clamp(to.x, 0, f32(p.width - 1)), clamp(to.y, 0, f32(p.length - 1))}
		if to != placement_point(&e.units, p.placements[e.selected]) {
			editor_placement_move(e, e.selected, to)
		}
	}
	if !rl.IsMouseButtonDown(.LEFT) {
		e.dragging_unit = false
	}
	if rl.IsMouseButtonPressed(.RIGHT) && e.hovered >= 0 {
		id := e.project.placements[e.hovered].unit
		if i := palette_find(e, id); i >= 0 {
			e.palette_unit = i
			editor_message(e, "Placing %s", id)
		}
	}
}

// The keys in the Units tab, when no text box has them.
units_keys :: proc(e: ^Editor, shift: bool) {
	if rl.IsKeyPressed(.ESCAPE) {
		e.selected = -1
	}
	if e.selected < 0 || e.selected >= len(e.project.placements) {
		return
	}
	step := shift ? 1 : TURN_STEP
	turns := placement_turns(e, e.project.placements[e.selected])
	switch {
	case rl.IsKeyPressed(.DELETE) || rl.IsKeyPressed(.BACKSPACE):
		editor_placement_delete(e, e.selected)
	case turns && (rl.IsKeyPressed(.Q) || rl.IsKeyPressedRepeat(.Q)):
		editor_placement_turn(e, e.selected, -step)
	case turns && (rl.IsKeyPressed(.E) || rl.IsKeyPressedRepeat(.E)):
		editor_placement_turn(e, e.selected, step)
	}
}

// The units over the view from above, whose map pixel (0, 0) is at `o`:
// the ground's, then the air's over them, as the game draws them. Fainter
// outside the Units tab, where the terrain is the work.
units_draw :: proc(e: ^Editor, o: [2]f32, area: rl.Rectangle) {
	z := f32(e.zoom)
	editing := Tab(e.tab) == .Units
	tint := editing ? rl.WHITE : rl.Color{255, 255, 255, 150}
	for ground in ([2]bool{true, false}) {
		for pl in e.project.placements {
			if placement_ground(&e.units, pl) != ground || !placement_shown(e, pl) {
				continue
			}
			at := o + placement_point(&e.units, pl) * z
			if at.y < area.y - 128 || at.y > area.y + area.height + 128 {
				continue
			}
			// Its base, which the original baked into the map, moving with
			// it; drawn over itself where the map already has it.
			if base, ok := catalogue_base(&e.units, pl.unit); ok && ground {
				size := [2]f32{f32(base.width), f32(base.height)}
				rl.DrawTextureEx(base, at - {math.floor(size.x / 2), math.floor(size.y / 2)} * z, 0, z, tint)
			}
			drawn := false
			if u := catalogue_unit(&e.units, pl.unit); u != nil {
				sprite, frame := unit_look(u, pl.heading_degrees)
				drawn = unit_draw(e, sprite, frame, at, z, tint)
			}
			if !drawn {
				// A unit this build lacks, or one with nothing to draw.
				r := PICK_MIN * z
				rl.DrawRectangleLinesEx({at.x - r, at.y - r, 2 * r, 2 * r}, 1, {255, 80, 200, tint.a})
				rl.DrawText(strings.clone_to_cstring(pl.unit, context.temp_allocator), i32(at.x + r + 2), i32(at.y - 5), 10, {255, 80, 200, tint.a})
			}
		}
	}
	if !editing {
		return
	}
	outline :: proc(e: ^Editor, o: [2]f32, i: int, colour: rl.Color) {
		pl := e.project.placements[i]
		z := f32(e.zoom)
		at := o + placement_point(&e.units, pl) * z
		half := placement_extent(e, pl) * z
		rl.DrawRectangleLinesEx({at.x - half.x - 1, at.y - half.y - 1, 2 * half.x + 2, 2 * half.y + 2}, 1, colour)
	}
	if e.hovered >= 0 && e.hovered < len(e.project.placements) && e.hovered != e.selected {
		outline(e, o, e.hovered, {255, 255, 255, 200})
	}
	if e.selected >= 0 && e.selected < len(e.project.placements) {
		outline(e, o, e.selected, SELECTED_COLOUR)
		// Where the screen's top is when it spawns.
		pl := e.project.placements[e.selected]
		row := o.y + f32(pl.y + SPAWN_AHEAD) * z
		x0, x1 := o.x, o.x + f32(e.project.width) * z
		for x := x0; x < x1; x += 12 {
			rl.DrawLineEx({x, row}, {min(x + 6, x1), row}, 1, SELECTED_COLOUR)
		}
		rl.DrawText("screen top at spawn", i32(max(x0, area.x) + 4), i32(row + 3), 10, SELECTED_COLOUR)
	}
}

// Draws a frame centred on `at`, `scale` screen pixels to the map pixel,
// as U_Sprite_Draw does; false when there is nothing to draw.
unit_draw :: proc(e: ^Editor, sprite: sim.Res_ID, frame: int, at: [2]f32, scale: f32, tint: rl.Color) -> bool {
	t, src, ok := catalogue_frame(&e.units, sprite, frame)
	if !ok {
		return false
	}
	half := [2]f32{math.floor(src.width / 2), math.floor(src.height / 2)} * scale
	rl.DrawTexturePro(t, src, {at.x - half.x, at.y - half.y, src.width * scale, src.height * scale}, {}, 0, tint)
	return true
}

// A frame's larger side, at least 1: what fits the palette's preview box.
@(private = "file")
unit_largest :: proc(e: ^Editor, sprite: sim.Res_ID, frame: int) -> f32 {
	size, ok := catalogue_frame_size(&e.units, sprite, frame)
	return ok ? max(size.x, size.y, 1) : 1
}

// The units on the overview, a dot each.
units_overview :: proc(e: ^Editor, s: f32, r: rl.Rectangle) {
	for pl in e.project.placements {
		if !placement_shown(e, pl) {
			continue
		}
		at := placement_point(&e.units, pl)
		colour := placement_ground(&e.units, pl) ? GROUND_COLOUR : AIR_COLOUR
		rl.DrawRectangleRec({r.x + at.x * s - 1, r.y + at.y * s - 1, 2, 2}, colour)
	}
}

// The unit under the mouse, for the status line.
units_status :: proc(e: ^Editor, sb: ^strings.Builder) {
	if e.hovered < 0 || e.hovered >= len(e.project.placements) {
		return
	}
	pl := e.project.placements[e.hovered]
	name := "not in this build"
	if u := catalogue_unit(&e.units, pl.unit); u != nil {
		name = u.name
	}
	fmt.sbprintf(sb, "   |   %s %s, heading %d", pl.unit, name, pl.heading_degrees)
}
