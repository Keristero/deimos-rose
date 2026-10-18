package editor

// The Models tab: the brush's profiles and their models, the library they
// are taken from, and the models put down, to pick and change one by one.

import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"

import rl "vendor:raylib"

import "dr:terrain"

// A list's height in the tab: four rows of LIST_ITEMS_HEIGHT (style_dark).
@(private = "file")
MODELS_LIST_HEIGHT :: 4 * 18 + 8

models_panel :: proc(e: ^Editor, x: f32, y: ^f32, w: f32, bottom: f32) {
	s := &e.scenery
	rl.GuiToggleGroup({x, y^, (w - 2 * 2) / 3, 20}, "Scatter;Erase;Select", &s.mode)
	y^ += ROW
	if Models_Mode(s.mode) == .Select {
		selected_panel(e, x, y, w)
		return
	}
	slider(x, y, w, "Size", &e.brush.radius, 1, 160, "%.0f px")
	if Models_Mode(s.mode) == .Erase {
		rl.GuiCheckBox({x, y^, 20, 20}, "Every model, not the profile's", &s.erase_any)
		y^ += ROW
	}
	profiles_panel(e, x, y, w)
	if s.profile >= 0 && s.profile < len(s.profiles) && Models_Mode(s.mode) == .Scatter {
		entries_panel(e, x, y, w)
	}
	library_panel(e, x, y, w, bottom)
}

@(private = "file")
profiles_panel :: proc(e: ^Editor, x: f32, y: ^f32, w: f32) {
	s := &e.scenery
	heading(x, y, w, s.profiles_dirty ? "Profiles *" : "Profiles")
	names := make([]cstring, len(s.profiles), context.temp_allocator)
	for pr, i in s.profiles {
		names[i] = fmt.ctprintf("%s", pr.name)
	}
	active, focus := c.int(s.profile), c.int(-1)
	rl.GuiListViewEx({x, y^, w, MODELS_LIST_HEIGHT}, raw_data(names), c.int(len(names)), &s.profile_scroll, &active, &focus)
	if int(active) != s.profile && int(active) < len(s.profiles) {
		s.profile, s.entry, s.name_edit = int(active), -1, false
	}
	y^ += MODELS_LIST_HEIGHT + 4
	bw := (w - 3 * 4) / 4
	if rl.GuiButton({x, y^, bw, 20}, "New") {
		profile_add(s, -1, fmt.tprintf("profile %d", len(s.profiles) + 1))
	}
	if s.profile < 0 {
		rl.GuiDisable()
	}
	if rl.GuiButton({x + bw + 4, y^, bw, 20}, "Copy") {
		profile_add(s, s.profile, fmt.tprintf("%s copy", s.profiles[s.profile].name))
	}
	if rl.GuiButton({x + 2 * (bw + 4), y^, bw, 20}, "Delete") {
		profile_remove(s, s.profile)
	}
	rl.GuiEnable()
	if rl.GuiButton({x + 3 * (bw + 4), y^, bw, 20}, "Save") {
		if profiles_save(s) {
			editor_message(e, "Profiles saved for every level")
		} else {
			editor_message(e, "Cannot save the profiles: no user data directory")
		}
	}
	y^ += ROW
	if s.profile < 0 || s.profile >= len(s.profiles) {
		help(x, y, w, {"No profile: New makes one."})
		return
	}
	pr := &s.profiles[s.profile]
	// The name, taken when the box is left.
	if !s.name_edit {
		box_set(s.name[:], pr.name)
	}
	rl.GuiLabel({x, y^, 96, 20}, "Name")
	if rl.GuiTextBox({x + 96, y^, w - 96, 20}, cstring(raw_data(s.name[:])), c.int(len(s.name) - 1), s.name_edit) {
		s.name_edit = !s.name_edit
		if name := box_text(s.name[:]); !s.name_edit && name != "" && name != pr.name {
			pr.name = strings.clone(name, scenery_allocator(s))
			s.profiles_dirty = true
		}
	}
	y^ += ROW
	before := pr^
	if Models_Mode(s.mode) == .Scatter {
		slider(x, y, w, "Spacing", &pr.spacing, 1, 128, "%.0f px")
		slider(x, y, w, "Density", &pr.density, 0, 1)
		range_slider(x, y, w, "Turn", &pr.turn, 0, 360, "%.0f")
		range_slider(x, y, w, "Lean", &pr.lean, 0, 45, "%.0f")
		slider(x, y, w, "Steepest", &pr.max_slope, 0, 90, "%.0f deg")
		rl.GuiCheckBox({x, y^, 20, 20}, "Not under the water", &pr.dry)
		y^ += ROW
	}
	if before.spacing != pr.spacing || before.density != pr.density || before.turn != pr.turn || before.lean != pr.lean || before.max_slope != pr.max_slope || before.dry != pr.dry {
		s.profiles_dirty = true
	}
}

// The profile's models, and the chosen one's chance, scale and lift.
@(private = "file")
entries_panel :: proc(e: ^Editor, x: f32, y: ^f32, w: f32) {
	s := &e.scenery
	pr := &s.profiles[s.profile]
	heading(x, y, w, "The profile's models")
	total: f32
	for en in pr.entries {
		total += max(en.chance, 0)
	}
	rows := make([]Asset_Row, len(pr.entries), context.temp_allocator)
	for en, i in pr.entries {
		l := library_find(s, en.model)
		missing := l < 0 ? "  (not in the library)" : ""
		rows[i] = {fmt.tprintf("%s%s%s  %.0f%%%s", en.model, en.variant != "" ? " / " : "", en.variant, total > 0 ? 100 * max(en.chance, 0) / total : 0, missing), l >= 0 && s.library[l].imported ? "imported" : ""}
	}
	active := c.int(s.entry)
	asset_list({x, y^, w, MODELS_LIST_HEIGHT}, rows, &s.entry_scroll, &active)
	if int(active) < len(pr.entries) {
		s.entry = int(active)
	}
	y^ += MODELS_LIST_HEIGHT + 4
	if s.entry < 0 || s.entry >= len(pr.entries) {
		help(x, y, w, {"Add models from the library below."})
		return
	}
	en := &pr.entries[s.entry]
	before := en^
	// Which of the file's models: any, or one.
	if l := library_find(s, en.model); l >= 0 {
		f := s.library[l].file
		sb := strings.builder_make(context.temp_allocator)
		strings.write_string(&sb, "Any of them")
		which := c.int(0)
		for v, k in f.variants {
			name, _ := strings.replace_all(v.name != "" ? v.name : fmt.tprintf("model %d", k + 1), ";", ",", context.temp_allocator)
			fmt.sbprintf(&sb, ";%s", name)
			if en.variant != "" && v.name == en.variant {
				which = c.int(k + 1)
			}
		}
		rl.GuiLabel({x, y^, 96, 20}, "Model")
		rl.GuiComboBox({x + 96, y^, w - 96, 20}, strings.to_cstring(&sb), &which)
		en.variant = which == 0 ? "" : f.variants[which - 1].name
		y^ += ROW
	}
	slider(x, y, w, "Chance", &en.chance, 0, 10, "%.1f")
	range_slider(x, y, w, "Scale", &en.scale, 0.1, 20, "%.1f")
	range_slider(x, y, w, "Lift", &en.offset, -16, 32, "%.0f")
	if rl.GuiButton({x, y^, w, 20}, "Take it out of the profile") {
		ordered_remove(&pr.entries, s.entry)
		s.entry = -1
		s.profiles_dirty = true
	} else if before != en^ {
		s.profiles_dirty = true
	}
	y^ += ROW
}

@(private = "file")
library_panel :: proc(e: ^Editor, x: f32, y: ^f32, w: f32, bottom: f32) {
	s := &e.scenery
	heading(x, y, w, "Library")
	if len(s.library) == 0 {
		import_button(e, x, y, w)
		help(x, y, w, {"No library: `mise run models:library`.", "Import a .glb, .gltf or .obj, or drop one", "on the window."})
		return
	}
	rows := make([]Asset_Row, len(s.library), context.temp_allocator)
	for m, i in s.library {
		rows[i] = {fmt.tprintf("%s  %d", m.file.name, len(m.file.variants)), m.imported ? "imported" : ""}
	}
	h := clamp(bottom - y^ - ROW - 60, MODELS_LIST_HEIGHT, 3 * MODELS_LIST_HEIGHT)
	asset_list({x, y^, w, h}, rows, &s.library_scroll, &s.library_pick)
	y^ += h + 4
	if s.profile < 0 || s.library_pick < 0 || Models_Mode(s.mode) != .Scatter {
		rl.GuiDisable()
	}
	if rl.GuiButton({x, y^, w, 20}, "Add to the profile") {
		profile_entry_add(s, s.profile, int(s.library_pick))
	}
	rl.GuiEnable()
	y^ += ROW
	if k := int(s.library_pick); k >= 0 && k < len(s.library) {
		m := s.library[k]
		hi := m.file.variants[0].hi
		help(x, y, w, {fmt.ctprintf("%.1f x %.1f m, %.1f m tall", 2 * hi.x, 2 * hi.z, hi.y), fmt.ctprintf("%s", m.source)})
	}
	import_button(e, x, y, w)
	help(x, y, w, {"Drag on the map to put models down.", "Or drop a model file on the window."})
}

@(private = "file")
import_button :: proc(e: ^Editor, x: f32, y: ^f32, w: f32) {
	if rl.GuiButton({x, y^, w, 20}, "Import a model...") && !editor_dialog(e, .Model) {
		editor_message(e, "No file dialog here: drop the model on the window")
	}
	y^ += ROW
}

// The model selected: where it is, its lift, turn, lean and scale.
@(private = "file")
selected_panel :: proc(e: ^Editor, x: f32, y: ^f32, w: f32) {
	s, p := &e.scenery, &e.project
	heading(x, y, w, "Selected")
	if s.instance < 0 || s.instance >= len(p.instances) {
		help(x, y, w, {"Click a model on the map to select it,", "and drag it to move it.", "Delete takes it away; Q and E turn it."})
		return
	}
	i := p.instances[s.instance]
	help(x, y, w, {fmt.ctprintf("%s at %.0f, %.0f", p.models[i.model].name, i.x, i.y)})
	slider(x, y, w, "Lift", &i.offset, -32, 64, "%.1f px")
	slider(x, y, w, "Turn", &i.turn, 0, 360, "%.0f deg")
	slider(x, y, w, "Lean", &i.lean, 0, 90, "%.0f deg")
	slider(x, y, w, "Scale", &i.scale, 0.05, 20, "%.2f")
	editor_instance_set(e, s.instance, i)
	if rl.GuiButton({x, y^, w, 20}, "Delete") {
		editor_instance_delete(e, s.instance)
	}
	y^ += ROW
}

// Two sliders for a range, from and to, the second kept over the first.
@(private = "file")
range_slider :: proc(x: f32, y: ^f32, w: f32, label: cstring, r: ^[2]f32, lo, hi: f32, format: string) {
	rl.GuiLabel({x, y^, 96, 20}, label)
	sw := (w - 96 - 4) / 2
	rl.GuiSliderBar({x + 96, y^ + 3, sw, 14}, nil, nil, &r[0], lo, hi)
	rl.GuiSliderBar({x + 96 + sw + 4, y^ + 3, sw, 14}, nil, nil, &r[1], lo, hi)
	r[1] = max(r[1], r[0])
	text := fmt.ctprintf("%s - %s", fmt.tprintf(format, r[0]), fmt.tprintf(format, r[1]))
	rl.GuiLabel({x + 96 + 2, y^ + 3, sw * 2, 14}, text)
	y^ += ROW
}

// The Select mode: the model under the mouse picked, and dragged.
models_select_input :: proc(e: ^Editor) {
	s, v, p := &e.scenery, &e.view, &e.project
	s.hovered = v.over_map ? instance_pick(e, v.cursor) : -1
	if rl.IsMouseButtonPressed(.LEFT) && v.over_map {
		s.instance = s.hovered
		s.dragging = s.instance >= 0
		if s.dragging {
			i := p.instances[s.instance]
			s.drag_offset = [2]f32{i.x, i.y} - v.cursor
		}
	} else if rl.IsMouseButtonDown(.LEFT) && s.dragging && s.instance >= 0 && s.instance < len(p.instances) {
		to := v.cursor + s.drag_offset
		i := p.instances[s.instance]
		i.x, i.y = clamp(to.x, 0, f32(p.width)), clamp(to.y, 0, f32(p.length))
		editor_instance_set(e, s.instance, i)
	}
	if !rl.IsMouseButtonDown(.LEFT) {
		s.dragging = false
	}
}

// The keys in the Models tab, when no text box has them.
models_keys :: proc(e: ^Editor, shift: bool) {
	s := &e.scenery
	if rl.IsKeyPressed(.ESCAPE) {
		s.instance = -1
	}
	if Models_Mode(s.mode) != .Select || s.instance < 0 || s.instance >= len(e.project.instances) {
		return
	}
	step := f32(shift ? 1 : TURN_STEP)
	i := e.project.instances[s.instance]
	switch {
	case rl.IsKeyPressed(.DELETE) || rl.IsKeyPressed(.BACKSPACE):
		editor_instance_delete(e, s.instance)
		return
	case rl.IsKeyPressed(.Q) || rl.IsKeyPressedRepeat(.Q):
		i.turn = math.mod(i.turn - step + 360, 360)
	case rl.IsKeyPressed(.E) || rl.IsKeyPressedRepeat(.E):
		i.turn = math.mod(i.turn + step, 360)
	}
	editor_instance_set(e, s.instance, i)
}

models_status :: proc(e: ^Editor, sb: ^strings.Builder) {
	s, p := &e.scenery, &e.project
	fmt.sbprintf(sb, "   |   %d models put down", len(p.instances))
	if k := s.hovered; k >= 0 && k < len(p.instances) {
		i := p.instances[k]
		fmt.sbprintf(sb, ": %s, lift %.1f, turn %.0f, scale %.2f", p.models[i.model].name, i.offset, i.turn, i.scale)
	}
}

// Over the view from above, whose map pixel (0, 0) is at `o`: in the
// Select mode, the model under the mouse and the one selected, ringed by
// how far they reach.
models_draw :: proc(e: ^Editor, o: [2]f32) {
	s, p := &e.scenery, &e.project
	if Models_Mode(s.mode) != .Select {
		return
	}
	z := f32(e.zoom)
	ring :: proc(p: ^terrain.Project, k: int, o: [2]f32, z: f32, colour: rl.Color) {
		if k < 0 || k >= len(p.instances) {
			return
		}
		i := p.instances[k]
		at := o + [2]f32{i.x, i.y} * z
		rl.DrawCircleLinesV(at, max(terrain.instance_reach(p, i), 2) * z, colour)
		rl.DrawCircleV(at, 1.5, colour)
	}
	ring(p, s.hovered, o, z, {255, 255, 255, 160})
	ring(p, s.instance, o, z, {255, 220, 90, 255})
}
