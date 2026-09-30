package editor

// The editor's window: the panels down the left (raygui), the views, the
// status line, and the mouse and keys.

import "core:c"
import "core:fmt"
import "core:strings"

import rl "vendor:raylib"

import "dr:data"
import "dr:terrain"

Tab :: enum c.int {
	Terrain,
	Light,
	Water,
	View,
	Units,
}

// An action that would lose unsaved changes, asked for once already.
Pending :: enum {
	None,
	Open,
	New,
}

Panel :: struct {
	tab:               c.int,
	path_edit:         bool,
	new_length:        c.int,
	length_edit:       bool,
	pending:           Pending,
	message:           [256]u8,
	message_until:     f64,
	dragging_overview: bool,
}

// Rows scrolled by a notch of the wheel.
WHEEL_ROWS :: 64
ROW :: 24

editor_message :: proc(e: ^Editor, format: string, args: ..any) {
	e.message = {}
	fmt.bprintf(e.message[:len(e.message) - 1], format, ..args)
	e.message_until = rl.GetTime() + 5
}

// raygui's dark palette, with an amber for what is pressed or chosen.
style_dark :: proc() {
	set :: proc(property: rl.GuiControlProperty, colour: rl.Color) {
		rl.GuiSetStyle(.DEFAULT, c.int(property), cast(c.int)rl.ColorToInt(colour))
	}
	rl.GuiLoadStyleDefault()
	set(.BORDER_COLOR_NORMAL, {110, 112, 118, 255})
	set(.BASE_COLOR_NORMAL, {52, 54, 60, 255})
	set(.TEXT_COLOR_NORMAL, {200, 202, 206, 255})
	set(.BORDER_COLOR_FOCUSED, {220, 190, 120, 255})
	set(.BASE_COLOR_FOCUSED, {78, 80, 88, 255})
	set(.TEXT_COLOR_FOCUSED, {240, 240, 240, 255})
	set(.BORDER_COLOR_PRESSED, {240, 196, 100, 255})
	set(.BASE_COLOR_PRESSED, {200, 146, 56, 255})
	set(.TEXT_COLOR_PRESSED, {24, 24, 24, 255})
	set(.BORDER_COLOR_DISABLED, {80, 80, 84, 255})
	set(.BASE_COLOR_DISABLED, {60, 60, 64, 255})
	set(.TEXT_COLOR_DISABLED, {110, 110, 114, 255})
	rl.GuiSetStyle(.DEFAULT, c.int(rl.GuiDefaultProperty.LINE_COLOR), cast(c.int)rl.ColorToInt({130, 132, 138, 255}))
	rl.GuiSetStyle(.DEFAULT, c.int(rl.GuiDefaultProperty.BACKGROUND_COLOR), cast(c.int)rl.ColorToInt({44, 46, 52, 255}))
	// A tick is drawn in the checkbox's text colour (its label in the
	// label's), and filled the box to its border: amber, and inset, reads
	// as ticked at a glance.
	rl.GuiSetStyle(.CHECKBOX, c.int(rl.GuiControlProperty.TEXT_COLOR_NORMAL), cast(c.int)rl.ColorToInt({200, 146, 56, 255}))
	rl.GuiSetStyle(.CHECKBOX, c.int(rl.GuiControlProperty.TEXT_COLOR_FOCUSED), cast(c.int)rl.ColorToInt({240, 196, 100, 255}))
	rl.GuiSetStyle(.CHECKBOX, c.int(rl.GuiCheckBoxProperty.CHECK_PADDING), 4)
	// The palette: a long list of names, read down the left.
	rl.GuiSetStyle(.LISTVIEW, c.int(rl.GuiListViewProperty.LIST_ITEMS_HEIGHT), 18)
	rl.GuiSetStyle(.LISTVIEW, c.int(rl.GuiControlProperty.TEXT_ALIGNMENT), c.int(rl.GuiTextAlignment.TEXT_ALIGN_LEFT))
	rl.GuiSetStyle(.LISTVIEW, c.int(rl.GuiControlProperty.TEXT_PADDING), 6)
}

// True when the action can go ahead: nothing unsaved, or asked twice.
@(private = "file")
guarded :: proc(e: ^Editor, action: Pending) -> bool {
	if !e.dirty || e.pending == action {
		e.pending = .None
		return true
	}
	e.pending = action
	editor_message(e, "Unsaved changes: once more to discard them")
	return false
}

// One frame in the window.
editor_frame :: proc(e: ^Editor) {
	l := layout(f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()))
	editor_input(e, l)
	view_prepare(e, l.view)
	rl.BeginDrawing()
	editor_draw(e, l)
	rl.EndDrawing()
}

// One frame drawn offscreen, width x height, as an RGB image: the headless
// shot, and what tests/editor looks at.
editor_shot :: proc(e: ^Editor, width, height: int) -> rl.Image {
	l := layout(f32(width), f32(height))
	view_prepare(e, l.view)
	canvas := rl.LoadRenderTexture(i32(width), i32(height))
	defer rl.UnloadRenderTexture(canvas)
	rl.BeginTextureMode(canvas)
	editor_draw(e, l)
	rl.EndTextureMode()
	img := rl.LoadImageFromTexture(canvas.texture)
	rl.ImageFlipVertical(&img) // render textures are bottom-up
	rl.ImageFormat(&img, .UNCOMPRESSED_R8G8B8)
	return img
}

editor_draw :: proc(e: ^Editor, l: Layout) {
	rl.ClearBackground({34, 36, 40, 255})
	view_draw(e, l)
	panel_draw(e, l.panel)
	status_draw(e, l.status)
	editor_settings_settle(e, rl.IsMouseButtonDown(.LEFT))
	placements_settle(e, rl.IsMouseButtonDown(.LEFT))
}

@(private = "file")
editor_input :: proc(e: ^Editor, l: Layout) {
	v, p := &e.view, &e.project
	mouse := rl.GetMousePosition()
	typing := e.path_edit || e.length_edit
	in_view := rl.CheckCollisionPointRec(mouse, l.view)
	in_overview := rl.CheckCollisionPointRec(mouse, l.overview)
	rows := view_rows(v, l.view)

	v.cursor = view_to_map(v, p, l.view, mouse)
	v.over_map = in_view && !v.tilted && v.cursor.x >= 0 && v.cursor.y >= 0 && v.cursor.x < f32(p.width) && v.cursor.y < f32(p.length)

	if wheel := rl.GetMouseWheelMove(); wheel != 0 && (in_view || in_overview) {
		if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) {
			v.left -= wheel * WHEEL_ROWS / f32(v.zoom)
		} else {
			v.row -= wheel * WHEEL_ROWS / f32(v.zoom)
		}
	}
	if rl.IsMouseButtonDown(.MIDDLE) && in_view {
		d := rl.GetMouseDelta()
		v.row -= d.y / f32(v.zoom)
		v.left -= d.x / f32(v.zoom)
	}

	// The brush, or in the Units tab the units.
	if Tab(e.tab) == .Units {
		units_input(e)
	} else if rl.IsMouseButtonPressed(.LEFT) && v.over_map {
		editor_stroke_begin(e, v.cursor)
	} else if rl.IsMouseButtonDown(.LEFT) && e.stroke {
		editor_stroke_to(e, v.cursor, rl.GetFrameTime() * DABS_PER_SECOND)
	}
	if rl.IsMouseButtonReleased(.LEFT) {
		editor_stroke_end(e)
	}
	if rl.IsMouseButtonPressed(.RIGHT) && v.over_map && Tab(e.tab) != .Units {
		e.brush.target = height_at(p, int(v.cursor.x), int(v.cursor.y))
		editor_message(e, "Target height %.1f", e.brush.target)
	}

	// The overview scrolls to where it is clicked.
	if rl.IsMouseButtonPressed(.LEFT) && in_overview {
		e.dragging_overview = true
	}
	if !rl.IsMouseButtonDown(.LEFT) {
		e.dragging_overview = false
	}
	if e.dragging_overview {
		s, r := overview_fit(p, l.overview)
		v.row = (mouse.y - r.y) / s - rows / 2
	}

	if rl.IsFileDropped() {
		files := rl.LoadDroppedFiles()
		if files.count > 0 {
			path := string(files.paths[0])
			if strings.has_suffix(path, terrain.PROJECT_SUFFIX) && guarded(e, .Open) {
				open_reporting(e, strings.clone(path, context.temp_allocator))
			}
		}
		rl.UnloadDroppedFiles(files)
	}

	if typing {
		return
	}
	ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
	shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
	switch {
	case ctrl && rl.IsKeyPressed(.Z) && !shift:
		editor_undo(e)
	case ctrl && (rl.IsKeyPressed(.Y) || rl.IsKeyPressed(.Z) && shift):
		editor_redo(e)
	case ctrl && rl.IsKeyPressed(.S):
		save_reporting(e)
	case rl.IsKeyPressed(.PAGE_UP):
		v.row -= rows * 0.9
	case rl.IsKeyPressed(.PAGE_DOWN):
		v.row += rows * 0.9
	case rl.IsKeyPressed(.HOME):
		v.row = 0
	case rl.IsKeyPressed(.END):
		v.row = f32(p.length)
	case rl.IsKeyPressed(.LEFT_BRACKET):
		e.brush.radius = max(e.brush.radius / 1.25, 1)
	case rl.IsKeyPressed(.RIGHT_BRACKET):
		e.brush.radius = min(e.brush.radius * 1.25, 160)
	case rl.IsKeyPressed(.L):
		v.live_light = !v.live_light
		v.view_stale, v.overview_stale = true, true
	case rl.IsKeyPressed(.T):
		v.tilted = !v.tilted
	case rl.IsKeyPressed(.U):
		e.show_units = !e.show_units
	case Tab(e.tab) == .Units:
		units_keys(e, shift)
	}
	for key, i in ([4]rl.KeyboardKey{.ONE, .TWO, .THREE, .FOUR}) {
		if rl.IsKeyPressed(key) && !ctrl {
			e.brush.mode = Brush_Mode(i)
		}
	}
}

// The surface's height at a map pixel, water not counted.
height_at :: proc(p: ^terrain.Project, x, y: int) -> f32 {
	i := clamp(y, 0, p.length - 1) * p.width + clamp(x, 0, p.width - 1)
	return p.heights[i]
}

@(private = "file")
open_reporting :: proc(e: ^Editor, path: string) {
	if editor_open(e, path) {
		editor_message(e, "Opened %s", path)
	} else {
		editor_message(e, "Cannot open %s", path)
	}
}

@(private = "file")
save_reporting :: proc(e: ^Editor) {
	path := strings.clone(editor_path(e), context.temp_allocator)
	switch {
	case !strings.has_suffix(path, terrain.PROJECT_SUFFIX):
		editor_message(e, "A project's name ends %s", terrain.PROJECT_SUFFIX)
	case editor_save(e, path):
		editor_message(e, "Saved %s", path)
	case:
		editor_message(e, "Cannot save %s", path)
	}
}

@(private = "file")
panel_draw :: proc(e: ^Editor, area: rl.Rectangle) {
	v, p := &e.view, &e.project
	rl.DrawRectangleRec(area, {44, 46, 52, 255})
	x, w := area.x + 8, area.width - 16
	y := area.y + 8

	// The project.
	rl.GuiLabel({x, y, w, 20}, "Project")
	y += 20
	if rl.GuiTextBox({x, y, w, 20}, cstring(raw_data(e.path[:])), c.int(len(e.path) - 1), e.path_edit) {
		e.path_edit = !e.path_edit
	}
	y += ROW
	bw := (w - 3 * 4) / 4
	if rl.GuiButton({x, y, bw, 20}, "Open") && guarded(e, .Open) {
		open_reporting(e, strings.clone(editor_path(e), context.temp_allocator))
	}
	if rl.GuiButton({x + (bw + 4), y, bw, 20}, "Save") {
		save_reporting(e)
	}
	if rl.GuiButton({x + 2 * (bw + 4), y, bw, 20}, "Undo") {
		editor_undo(e)
	}
	if rl.GuiButton({x + 3 * (bw + 4), y, bw, 20}, "Redo") {
		editor_redo(e)
	}
	y += ROW
	rl.GuiLabel({x, y, 60, 20}, "New, rows")
	if rl.GuiValueBox({x + 64, y, w - 64 - bw - 4, 20}, nil, &e.new_length, 1, 16384, e.length_edit) != 0 {
		e.length_edit = !e.length_edit
	}
	if rl.GuiButton({x + w - bw, y, bw, 20}, "New") && guarded(e, .New) {
		editor_new(e, int(e.new_length), "untitled" + terrain.PROJECT_SUFFIX)
		editor_message(e, "New level, %d x %d", NEW_WIDTH, e.new_length)
	}
	y += ROW + 8

	tw := (w - 4 * 2) / 5
	rl.GuiToggleGroup({x, y, tw, 20}, "Terrain;Light;Water;View;Units", &e.tab)
	y += ROW + 8

	lighting := p.level.lighting
	zoom, live := v.zoom, v.live_light
	switch Tab(e.tab) {
	case .Terrain:
		heading(x, &y, w, "Brush")
		mode := c.int(e.brush.mode)
		rl.GuiToggleGroup({x, y, (w - 3 * 2) / 4, 20}, "Raise;Lower;Flatten;Smooth", &mode)
		e.brush.mode = Brush_Mode(mode)
		y += ROW
		shape := c.int(e.brush.shape)
		rl.GuiToggleGroup({x, y, (w - 2 * 2) / 3, 20}, "Round;Square;Rough", &shape)
		e.brush.shape = Brush_Shape(shape)
		y += ROW
		slider(x, &y, w, "Size", &e.brush.radius, 1, 160, "%.0f px")
		slider(x, &y, w, "Strength", &e.brush.strength, 0, 1)
		slider(x, &y, w, "Falloff", &e.brush.falloff, 0, 1)
		slider(x, &y, w, "Target height", &e.brush.target, 0, height_range(e), "%.1f")
		y += 4
		help(x, &y, w, {"Drag on the map to sculpt.", "Right-click the map to take its height", "as Flatten's target.", "1-4: the mode.  [ and ]: the size.", "Ctrl+Z, Ctrl+Y: undo, redo.  Ctrl+S: save."})
	case .Light:
		rl.GuiCheckBox({x, y, 20, 20}, "Live lighting (L)", &v.live_light)
		y += ROW
		l := &p.level.lighting
		slider(x, &y, w, "Sun azimuth", &l.sun_azimuth_degrees, 0, 360, "%.0f deg")
		slider(x, &y, w, "Sun elevation", &l.sun_elevation_degrees, 1, 90, "%.0f deg")
		slider(x, &y, w, "Ambient", &l.ambient, 0, 1)
		slider(x, &y, w, "Softness", &l.softness, 0, 16, "%.1f px")
		colour(x, &y, w, "Sun colour", &l.sun_colour)
		colour(x, &y, w, "Ambient colour", &l.ambient_colour)
		y += 4
		bw3 := (w - 2 * 4) / 3
		if rl.GuiButton({x, y, bw3, 20}, "Copy") {
			editor_lighting_copy(e)
			editor_message(e, "Light copied as JSON")
		}
		if rl.GuiButton({x + bw3 + 4, y, bw3, 20}, "Paste") {
			if editor_lighting_paste(e) {
				editor_message(e, "Light pasted")
			} else {
				editor_message(e, "The clipboard holds no light")
			}
		}
		if rl.GuiButton({x + 2 * (bw3 + 4), y, bw3, 20}, "Reset to original") {
			p.level.lighting = data.LIGHTING_MEASURED
			editor_message(e, "The originals' light, as measured")
		}
		y += ROW + 4
		help(x, &y, w, {"Copy and paste carry the light between", "levels, as JSON; a level record's", "light pastes too."})
	case .Water:
		wt := &p.level.water
		heading(x, &y, w, "Water")
		rl.GuiCheckBox({x, y, 20, 20}, "Show the water", &wt.visible)
		y += ROW
		slider(x, &y, w, "Height", &wt.height, 0, height_range(e), "%.1f")
		colour(x, &y, w, "Colour", &wt.colour)
		if p.water != nil {
			help(x, &y, w, {"A baked water layer, the originals'", "shallows, colours the water; ground", "lowered under it takes this colour."})
		}
		y += 8
		heading(x, &y, w, "Wind")
		wd := &p.level.wind
		slider(x, &y, w, "Direction", &wd.direction_degrees, 0, 360, "%.0f deg")
		slider(x, &y, w, "Strength", &wd.strength, 0, 1)
	case .View:
		heading(x, &y, w, "View")
		z := c.int(v.zoom - 1)
		rl.GuiToggleGroup({x, y, (w - 2) / 2, 20}, "1x;2x", &z)
		v.zoom = int(z) + 1
		y += ROW
		rl.GuiCheckBox({x, y, 20, 20}, "Tilted (T)", &v.tilted)
		y += ROW
		rl.GuiCheckBox({x, y, 20, 20}, "Show the units (U)", &e.show_units)
		y += ROW
		slider(x, &y, w, "Tilt", &v.tilt, 5, 85, "%.0f deg")
		slider(x, &y, w, "Turn", &v.turn, -180, 180, "%.0f deg")
		y += 4
		help(x, &y, w, {"Wheel: scroll.  Shift+wheel: across.", "Middle-drag: pan.  Page Up, Page Down,", "Home, End: along the level.", "Click the strip on the right to go there.", "The tilted view is to look at; sculpt", "from above."})
	case .Units:
		units_panel(e, x, &y, w, area.y + area.height)
	}
	if p.level.lighting != lighting || v.zoom != zoom || v.live_light != live {
		v.view_stale = true
		if v.live_light != live || p.level.lighting != lighting {
			v.overview_stale = true
		}
	}
}

// The highest a height slider goes: over the ground's top, in steps of 64.
@(private = "file")
height_range :: proc(e: ^Editor) -> f32 {
	return f32(int(max(e.renderer.surface_max, 64) / 64) + 1) * 64
}

heading :: proc(x: f32, y: ^f32, w: f32, text: cstring) {
	rl.GuiLine({x, y^, w, 16}, text)
	y^ += 20
}

slider :: proc(x: f32, y: ^f32, w: f32, label: cstring, value: ^f32, lo, hi: f32, format := "%.2f") {
	rl.GuiLabel({x, y^, 96, 20}, label)
	rl.GuiSlider({x + 96, y^, w - 96 - 56, 20}, nil, fmt.ctprintf(format, value^), value, lo, hi)
	y^ += ROW
}

@(private = "file")
colour :: proc(x: f32, y: ^f32, w: f32, label: cstring, c: ^[3]u8) {
	rl.GuiLabel({x, y^, 96, 20}, label)
	sw := (w - 96 - 20 - 2 * 4) / 3
	for i in 0 ..< 3 {
		f := f32(c[i])
		rl.GuiSliderBar({x + 96 + f32(i) * (sw + 4), y^ + 3, sw, 14}, nil, nil, &f, 0, 255)
		c[i] = u8(f + 0.5)
	}
	rl.DrawRectangleRec({x + w - 16, y^ + 2, 16, 16}, {c.r, c.g, c.b, 255})
	y^ += ROW
}

help :: proc(x: f32, y: ^f32, w: f32, lines: []cstring) {
	for line in lines {
		rl.GuiLabel({x, y^, w, 14}, line)
		y^ += 14
	}
	y^ += 4
}

@(private = "file")
status_draw :: proc(e: ^Editor, area: rl.Rectangle) {
	v, p := &e.view, &e.project
	name := editor_path(e)
	if i := strings.last_index_any(name, "/\\"); i >= 0 {
		name = name[i + 1:]
	}
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "%s%s   %d x %d   row %d", name, e.dirty ? " *" : "", p.width, p.length, int(v.row))
	if v.over_map {
		x, y := int(v.cursor.x), int(v.cursor.y)
		fmt.sbprintf(&sb, "   at %d, %d: height %.1f", x, y, height_at(p, x, y))
		if p.level.water.visible && height_at(p, x, y) < p.level.water.height {
			fmt.sbprintf(&sb, ", under water")
		}
	}
	if Tab(e.tab) == .Units {
		units_status(e, &sb)
	}
	if rl.GetTime() < e.message_until {
		fmt.sbprintf(&sb, "   |   %s", string(cstring(raw_data(e.message[:]))))
	}
	rl.GuiStatusBar(area, strings.to_cstring(&sb))
}
