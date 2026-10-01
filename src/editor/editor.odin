package editor

// The level editor's state, and what it does to a project apart from the
// window: open, make, save, sculpt, paint, put down models, undo, relight,
// place units. The window and its panels are in view.odin and panel.odin;
// tests/editor drives these directly.

import "core:encoding/json"
import "core:math"
import "core:mem/virtual"
import "core:strings"

import rl "vendor:raylib"

import "dr:data"
import "dr:terrain"

// A new level: the originals' width and length.
NEW_WIDTH :: 480
NEW_LENGTH :: 3600
// Its ground and its water, which lowering the ground below shows.
NEW_GROUND :: 48
NEW_WATER :: data.Level_Water {
	height  = 24,
	colour  = {40, 72, 96},
	visible = true,
}
NEW_MATERIAL :: terrain.Material {
	name   = "ground",
	colour = {150, 132, 104},
}

Editor :: struct {
	project:     terrain.Project,
	has_project: bool,
	// The project's memory, all freed when another is opened. On the heap:
	// the project's allocators point at it.
	arena:       ^virtual.Arena,
	path:        [1024]u8, // where it saves, NUL-terminated for the text box
	renderer:    terrain.Renderer,
	history:     History,
	// The settings as last recorded, to tell a finished change from one
	// still being dragged.
	settings:    Settings,
	dirty:       bool,
	brush:       Brush,
	stroke:      bool,
	last_dab:    [2]f32,
	// What can be placed: catalogue_load's, or a test's own.
	units:         Catalogue,
	// The materials a level can start from: library_load's.
	library:       Library,
	paint:         Paint,
	// The models, their library and the brush's profiles.
	scenery:       Scenery,
	level_panel:   Level_Panel,
	// The touchpad's pinch and smooth scroll, in a window; none in a shot.
	gestures:      Gestures,
	// The system's file dialog, in a window; none in a shot.
	dialog:        File_Dialog,
	using placing: Placing,
	using view:    View,
	using panel:   Panel,
}

editor_init :: proc(e: ^Editor) {
	e.brush = BRUSH_DEFAULT
	e.zoom = 1
	e.live_light = true
	e.tilt = 45
	e.new_length = NEW_LENGTH
	placing_init(&e.placing)
	e.paint.material, e.paint.library_pick = -1, -1
	e.level_panel.editing = -1
	scenery_init(&e.scenery)
	style_dark()
}

editor_destroy :: proc(e: ^Editor) {
	view_destroy(&e.view)
	terrain.renderer_destroy(&e.renderer)
	history_destroy(&e.history)
	catalogue_destroy(&e.units)
	library_destroy(&e.library)
	scenery_destroy(&e.scenery)
	placing_destroy(&e.placing)
	arena_free(e.arena)
	e.arena, e.has_project = nil, false
}

editor_path :: proc(e: ^Editor) -> string {
	return string(cstring(raw_data(e.path[:])))
}

editor_set_path :: proc(e: ^Editor, path: string) {
	e.path = {}
	copy(e.path[:len(e.path) - 1], path)
}

// Opens the project at `path`, in place of the one open. Needs the window.
editor_open :: proc(e: ^Editor, path: string) -> bool {
	arena := arena_new() or_return
	p, ok := terrain.project_load(path, virtual.arena_allocator(arena))
	if !ok {
		arena_free(arena)
		return false
	}
	editor_take(e, p, arena)
	editor_set_path(e, path)
	return true
}

// A new level, flat, `length` rows long, in place of the one open.
editor_new :: proc(e: ^Editor, length: int, path: string) -> bool {
	if length <= 0 {
		return false
	}
	arena := arena_new() or_return
	p := terrain.project_make(NEW_WIDTH, length, virtual.arena_allocator(arena))
	for &h in p.heights {
		h = NEW_GROUND
	}
	append(&p.materials, NEW_MATERIAL)
	p.level.water = NEW_WATER
	editor_take(e, p, arena)
	editor_set_path(e, path)
	e.dirty = true
	return true
}

// Makes `p`, held in `arena`, the project open.
@(private = "file")
editor_take :: proc(e: ^Editor, p: terrain.Project, arena: ^virtual.Arena) {
	arena_free(e.arena)
	e.project, e.arena, e.has_project = p, arena, true
	history_clear(&e.history)
	e.settings = settings_of(&e.project)
	e.dirty, e.stroke = false, false
	e.selected, e.hovered = -1, -1
	e.dragging_unit, e.placements_changing = false, false
	e.scenery.instance, e.scenery.hovered = -1, -1
	e.scenery.dragging, e.scenery.changing = false, false
	e.paint.material = len(p.materials) > 0 ? 0 : -1
	e.level_panel.editing = -1
	terrain.renderer_init(&e.renderer, &e.project)
	view_reset(&e.view, &e.project)
}

@(private = "file")
arena_new :: proc() -> (a: ^virtual.Arena, ok: bool) {
	a = new(virtual.Arena)
	if virtual.arena_init_growing(a) != nil {
		free(a)
		return nil, false
	}
	return a, true
}

@(private = "file")
arena_free :: proc(a: ^virtual.Arena) {
	if a != nil {
		virtual.arena_destroy(a)
		free(a)
	}
}

editor_save :: proc(e: ^Editor, path: string) -> bool {
	if !e.has_project || !strings.has_suffix(path, terrain.PROJECT_SUFFIX) {
		return false
	}
	if !terrain.project_save(&e.project, path) {
		return false
	}
	editor_set_path(e, path)
	e.dirty = false
	return true
}

// Starts a stroke at `at` (map pixels) with the brush: in the Paint tab,
// of the chosen material's weight, the weights made when there are none;
// in the Models tab, of the profile's models, recorded as the instances
// before it.
editor_stroke_begin :: proc(e: ^Editor, at: [2]f32) {
	if Tab(e.tab) == .Models {
		if Models_Mode(e.scenery.mode) == .Select {
			return
		}
		instances_changing(e)
		e.stroke = true
		e.last_dab = at
		editor_dab(e, at, 1)
		return
	}
	if Tab(e.tab) == .Paint {
		if e.paint.material < 0 || e.paint.material >= len(e.project.materials) {
			return
		}
		terrain.project_splat(&e.project, virtual.arena_allocator(e.arena))
	}
	history_begin(&e.history)
	e.stroke = true
	e.last_dab = at
	editor_dab(e, at, 1)
}

// Carries the stroke on to `at`: dabs a quarter of the radius apart along
// the way, sharing `amount` of a full dab between them.
editor_stroke_to :: proc(e: ^Editor, at: [2]f32, amount: f32) {
	if !e.stroke {
		return
	}
	d := at - e.last_dab
	gap := max(e.brush.radius / 4, 1)
	n := max(int(math.ceil(math.sqrt(d.x * d.x + d.y * d.y) / gap)), 1)
	for k in 1 ..= n {
		editor_dab(e, e.last_dab + d * f32(k) / f32(n), amount / f32(n))
	}
	e.last_dab = at
}

editor_stroke_end :: proc(e: ^Editor) {
	if !e.stroke {
		return
	}
	if Tab(e.tab) == .Models {
		e.stroke = false
		instances_settle(e, false)
		return
	}
	history_end(&e.history)
	e.stroke = false
	e.overview_stale = true
}

@(private = "file")
editor_dab :: proc(e: ^Editor, at: [2]f32, amount: f32) {
	area: terrain.Rect
	if Tab(e.tab) == .Models {
		put := Models_Mode(e.scenery.mode) == .Erase ? erase_dab(e, at) : scatter_dab(e, at)
		if put {
			instances_drawn(e)
			e.dirty = true
		}
		return
	}
	if Tab(e.tab) == .Paint {
		area = paint_dab(&e.project, e.brush, Paint_Mode(e.paint.mode), e.paint.material, at, amount, &e.history)
	} else {
		area = brush_dab(&e.project, e.brush, at, amount, &e.history)
	}
	if area.x1 > area.x0 {
		terrain.renderer_update(&e.renderer, &e.project, area)
		e.dirty = true
		e.view_stale = true
	}
}

editor_undo :: proc(e: ^Editor) -> bool {
	editor_stroke_end(e)
	placements_settle(e, false)
	instances_settle(e, false)
	c, ok := history_undo(&e.history, &e.project)
	editor_changed(e, c)
	return ok
}

editor_redo :: proc(e: ^Editor) -> bool {
	editor_stroke_end(e)
	placements_settle(e, false)
	instances_settle(e, false)
	c, ok := history_redo(&e.history, &e.project)
	editor_changed(e, c)
	return ok
}

@(private = "file")
editor_changed :: proc(e: ^Editor, c: Change) {
	if c.map_ {
		terrain.renderer_update(&e.renderer, &e.project, c.area)
	}
	if c.materials {
		terrain.renderer_materials(&e.renderer, &e.project)
		if e.paint.material >= len(e.project.materials) {
			e.paint.material = len(e.project.materials) - 1
		}
	}
	if c.map_ || c.settings || c.materials {
		e.settings = settings_of(&e.project)
		e.dirty = true
		e.view_stale, e.overview_stale = true, true
	}
	if c.instances {
		e.scenery.instance, e.scenery.hovered, e.scenery.dragging = -1, -1, false
		instances_drawn(e)
		e.dirty, e.overview_stale = true, true
	}
	// The units are drawn over the views each frame: nothing to redraw.
	if c.placements {
		// The list is another; what was selected may not be in it.
		e.selected, e.hovered, e.dragging_unit = -1, -1, false
		e.dirty = true
	}
}

// Records the settings once they have changed and nothing is being
// dragged, so a slider's drag undoes as one change.
editor_settings_settle :: proc(e: ^Editor, dragging: bool) {
	now := settings_of(&e.project)
	if now == e.settings {
		return
	}
	e.view_stale = true
	if dragging {
		return
	}
	history_settings(&e.history, e.settings)
	e.settings = now
	e.dirty = true
	e.overview_stale = true
}

// The light as JSON, for the clipboard: copied from one level, pasted
// into another.
lighting_json :: proc(l: data.Level_Lighting, allocator := context.allocator) -> string {
	blob, _ := json.marshal(l, {pretty = true, use_spaces = true, spaces = 2}, allocator)
	return string(blob)
}

// Light from JSON: the light alone, or a whole level record's. A field
// left out keeps LIGHTING_MEASURED's value, as a level record's does.
lighting_parse :: proc(s: string) -> (l: data.Level_Lighting, ok: bool) {
	l = data.LIGHTING_MEASURED
	v, err := json.parse_string(s, allocator = context.temp_allocator)
	if err != nil {
		return
	}
	obj, is_obj := v.(json.Object)
	if !is_obj {
		return
	}
	light := v
	if inner, has := obj["lighting"]; has {
		light = inner
	}
	blob, merr := json.marshal(light, allocator = context.temp_allocator)
	if merr != nil || json.unmarshal(blob, &l, allocator = context.temp_allocator) != nil {
		return data.LIGHTING_MEASURED, false
	}
	return l, true
}

editor_lighting_copy :: proc(e: ^Editor) {
	rl.SetClipboardText(strings.clone_to_cstring(lighting_json(e.project.level.lighting, context.temp_allocator), context.temp_allocator))
}

editor_lighting_paste :: proc(e: ^Editor) -> bool {
	l, ok := lighting_parse(string(rl.GetClipboardText()))
	if ok {
		e.project.level.lighting = l
	}
	return ok
}
