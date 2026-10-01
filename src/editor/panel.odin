package editor

// The editor's window: the panels down the left (raygui), the views, the
// status line, and the mouse and keys.

import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"

import rl "vendor:raylib"

import "dr:data"
import "dr:terrain"

Tab :: enum c.int {
	Terrain,
	Paint,
	Models,
	Light,
	Water,
	View,
	Units,
	Level,
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
// The zoom's factor for a notch of the wheel with Ctrl held, and for a
// press of Ctrl and + or -. A touchpad's wheel moves in fractions of a
// notch, so the wheel's is a power of it.
ZOOM_WHEEL :: 1.1
ZOOM_KEY :: 1.25
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
	panel_draw(e, l.panel, l.view)
	status_draw(e, l.status)
	editor_settings_settle(e, rl.IsMouseButtonDown(.LEFT))
	placements_settle(e, rl.IsMouseButtonDown(.LEFT))
	instances_settle(e, rl.IsMouseButtonDown(.LEFT))
}

@(private = "file")
editor_input :: proc(e: ^Editor, l: Layout) {
	v, p := &e.view, &e.project
	mouse := rl.GetMousePosition()
	typing := e.path_edit || e.length_edit || e.level_panel.editing >= 0 || e.scenery.name_edit
	in_view := rl.CheckCollisionPointRec(mouse, l.view)
	in_overview := rl.CheckCollisionPointRec(mouse, l.overview)
	rows := view_rows(v, l.view)

	v.cursor = view_to_map(v, p, l.view, mouse)
	v.over_map = in_view && !v.tilted && v.cursor.x >= 0 && v.cursor.y >= 0 && v.cursor.x < f32(p.width) && v.cursor.y < f32(p.length)

	ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
	shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
	// Zooms about the mouse in the view, else about the view's middle.
	centre := [2]f32{l.view.x + l.view.width / 2, l.view.y + l.view.height / 2}
	about := in_view ? mouse : centre
	// Polled every frame, so a pinch or a scroll elsewhere is not kept for
	// later.
	g := gestures_poll(&e.gestures)
	if g.zoom != 1 && in_view {
		view_zoom_at(v, p, l.view, mouse, g.zoom)
	}
	// Both of the wheel's axes: a touchpad's two fingers scroll across as
	// well as along, and raylib's GetMouseWheelMove keeps only the larger.
	wheel := g.smooth ? g.scroll : rl.GetMouseWheelMoveV()
	if wheel != 0 && (in_view || in_overview) {
		// Ctrl and the wheel zoom, as in most editors; and so does a pinch
		// on Windows' precision touchpads, which it sends as just that.
		if ctrl {
			view_zoom_at(v, p, l.view, about, math.pow(f32(ZOOM_WHEEL), wheel.y))
		} else {
			if shift {
				wheel = {wheel.y, wheel.x}
			}
			v.left -= wheel.x * WHEEL_ROWS / v.zoom
			v.row -= wheel.y * WHEEL_ROWS / v.zoom
		}
	}
	if rl.IsMouseButtonDown(.MIDDLE) && in_view {
		d := rl.GetMouseDelta()
		v.row -= d.y / v.zoom
		v.left -= d.x / v.zoom
	}

	// The brush, or in the Units tab the units, or the models to select.
	if Tab(e.tab) == .Units {
		units_input(e)
	} else if Tab(e.tab) == .Models && Models_Mode(e.scenery.mode) == .Select {
		models_select_input(e)
	} else if rl.IsMouseButtonPressed(.LEFT) && v.over_map {
		editor_stroke_begin(e, v.cursor)
	} else if rl.IsMouseButtonDown(.LEFT) && e.stroke {
		editor_stroke_to(e, v.cursor, rl.GetFrameTime() * DABS_PER_SECOND)
	}
	if rl.IsMouseButtonReleased(.LEFT) {
		editor_stroke_end(e)
	}
	if rl.IsMouseButtonPressed(.RIGHT) && v.over_map && Tab(e.tab) == .Terrain {
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
		// A project opens; a model goes into the library; an image becomes
		// a material.
		for i in 0 ..< files.count {
			path := strings.clone(string(files.paths[i]), context.temp_allocator)
			lower := strings.to_lower(path, context.temp_allocator)
			switch {
			case strings.has_suffix(path, terrain.PROJECT_SUFFIX):
				if guarded(e, .Open) {
					open_reporting(e, path)
				}
			case strings.has_suffix(lower, ".glb") || strings.has_suffix(lower, ".gltf") || strings.has_suffix(lower, ".obj"):
				if k := editor_model_import(e, path); k >= 0 {
					e.tab = c.int(Tab.Models)
					editor_message(e, "Model %s imported", e.scenery.library[k].file.name)
				} else {
					editor_message(e, "Cannot read %s as a model", path)
				}
			case editor_material_add_file(e, path):
				e.tab = c.int(Tab.Paint)
				editor_message(e, "Material %s added", e.project.materials[len(e.project.materials) - 1].name)
			case len(e.project.materials) >= terrain.MAX_MATERIALS:
				editor_message(e, "A level has at most %d materials", terrain.MAX_MATERIALS)
			case:
				editor_message(e, "Cannot read %s as an image", path)
			}
		}
		rl.UnloadDroppedFiles(files)
	}

	if typing {
		return
	}
	switch {
	case ctrl && (rl.IsKeyPressed(.EQUAL) || rl.IsKeyPressed(.KP_ADD)):
		view_zoom_at(v, p, l.view, about, ZOOM_KEY)
	case ctrl && (rl.IsKeyPressed(.MINUS) || rl.IsKeyPressed(.KP_SUBTRACT)):
		view_zoom_at(v, p, l.view, about, 1 / ZOOM_KEY)
	case ctrl && (rl.IsKeyPressed(.ZERO) || rl.IsKeyPressed(.KP_0)):
		view_zoom_at(v, p, l.view, about, 1 / v.zoom)
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
	case Tab(e.tab) == .Models:
		models_keys(e, shift)
	}
	for key, i in ([4]rl.KeyboardKey{.ONE, .TWO, .THREE, .FOUR}) {
		if rl.IsKeyPressed(key) && !ctrl {
			if Tab(e.tab) == .Paint {
				e.paint.mode = c.int(min(i, int(max(Paint_Mode))))
			} else if Tab(e.tab) == .Models {
				e.scenery.mode = c.int(min(i, int(max(Models_Mode))))
			} else {
				e.brush.mode = Brush_Mode(i)
			}
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
panel_draw :: proc(e: ^Editor, area, view: rl.Rectangle) {
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

	// Two rows, raygui's "\n": eight do not fit across.
	tw := (w - 3 * 2) / 4
	rl.GuiToggleGroup({x, y, tw, 20}, "Terrain;Paint;Models;Light\nWater;View;Units;Level", &e.tab)
	y += 2 * ROW + 8
	if Tab(e.tab) != .Level {
		level_panel_leave(e)
	}

	lighting := p.level.lighting
	live := v.live_light
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
		// The presets, and between them a slider by powers of two, so 1x
		// is its middle; both zoom about the view's middle.
		middle := [2]f32{view.x + view.width / 2, view.y + view.height / 2}
		presets := [?]f32{0.25, 0.5, 1, 2, 4}
		z := c.int(-1)
		for q, i in presets {
			if v.zoom == q {
				z = c.int(i)
			}
		}
		was := z
		rl.GuiToggleGroup({x, y, (w - 4 * 2) / 5, 20}, "1/4x;1/2x;1x;2x;4x", &z)
		if z != was && z >= 0 {
			view_zoom_at(v, p, view, middle, presets[z] / v.zoom)
		}
		y += ROW
		power := math.log2(v.zoom)
		rl.GuiLabel({x, y, 96, 20}, "Zoom")
		rl.GuiSlider({x + 96, y, w - 96 - 56, 20}, nil, fmt.ctprintf("%.0f%%", v.zoom * 100), &power, math.log2(f32(ZOOM_MIN)), math.log2(f32(ZOOM_MAX)))
		if zoom := math.pow(2, power); abs(zoom - v.zoom) > 1e-4 {
			view_zoom_at(v, p, view, middle, zoom / v.zoom)
		}
		y += ROW
		rl.GuiCheckBox({x, y, 20, 20}, "Tilted (T)", &v.tilted)
		y += ROW
		rl.GuiCheckBox({x, y, 20, 20}, "Show the units (U)", &e.show_units)
		y += ROW
		slider(x, &y, w, "Tilt", &v.tilt, 5, 85, "%.0f deg")
		slider(x, &y, w, "Turn", &v.turn, -180, 180, "%.0f deg")
		y += 4
		help(x, &y, w, {"Wheel, two fingers: scroll; Shift+wheel", "scrolls across.", "Ctrl+wheel, a touchpad's pinch: zoom.", "Ctrl+= and Ctrl+-: zoom; Ctrl+0: 1x.", "Middle-drag: pan.  Page Up, Page Down,", "Home, End: along the level.", "Click the strip on the right to go there.", "The tilted view is to look at; sculpt", "from above."})
	case .Paint:
		paint_panel(e, x, &y, w)
	case .Models:
		models_panel(e, x, &y, w, area.y + area.height)
	case .Units:
		units_panel(e, x, &y, w, area.y + area.height)
	case .Level:
		level_panel(e, x, &y, w)
	}
	if p.level.lighting != lighting || v.live_light != live {
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
	fmt.sbprintf(&sb, "%s%s   %d x %d   row %d   zoom %.0f%%", name, e.dirty ? " *" : "", p.width, p.length, int(v.row), v.zoom * 100)
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
	if Tab(e.tab) == .Models {
		models_status(e, &sb)
	}
	if rl.GetTime() < e.message_until {
		fmt.sbprintf(&sb, "   |   %s", string(cstring(raw_data(e.message[:]))))
	}
	rl.GuiStatusBar(area, strings.to_cstring(&sb))
}
