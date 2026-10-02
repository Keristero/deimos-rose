package editor_tests

// The level editor (Stages 7 to 9 of notes/level-editor-plan.md). The
// brush, undo, the light's JSON and placing units run anywhere; the editor itself draws, so its
// cases share one hidden window and skip when there is no display (mise
// run test runs them under xvfb-run), as tests/terrain's do. The le07 case
// needs a recovered project (mise run terrain:recover) and skips without.

import "core:c"
import "core:dynlib"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import rl "vendor:raylib"

import "dr:data"
import "dr:editor"
import "dr:terrain"

OUT :: "build/editor_test"
LE07 :: "../work/recovered/le07/le07.drproj.json"

// Rolling ground with water at 9 over a layer that holds none yet.
hills :: proc(w, l: int, allocator := context.allocator) -> terrain.Project {
	p := terrain.project_make(w, l, allocator)
	p.albedo = make([]u8, w * l * 3, allocator)
	p.water = make([]u8, w * l * 4, allocator)
	for y in 0 ..< l {
		for x in 0 ..< w {
			fx, fy := f32(x), f32(y)
			p.heights[y * w + x] = 14 + 8 * math.sin(fx * 0.11) * math.cos(fy * 0.07) + 3 * math.sin((fx + fy) * 0.23)
			c := p.albedo[(y * w + x) * 3:][:3]
			c[0], c[1], c[2] = u8(80 + x % 50), u8(120 + y % 60), 90
		}
	}
	p.level.water = {height = 9, colour = {20, 60, 110}, visible = true}
	return p
}

@(private = "file")
Snapshot :: struct {
	heights: []f32,
	water:   []u8,
}

@(private = "file")
snapshot :: proc(p: ^terrain.Project) -> Snapshot {
	s := Snapshot{make([]f32, len(p.heights), context.temp_allocator), make([]u8, len(p.water), context.temp_allocator)}
	copy(s.heights, p.heights)
	copy(s.water, p.water)
	return s
}

@(private = "file")
same :: proc(p: ^terrain.Project, s: Snapshot) -> bool {
	return string(transmute([]u8)p.heights) == string(transmute([]u8)s.heights) && string(p.water) == string(s.water)
}

// Strokes of every mode and shape, across tile edges and the water line,
// undo to the bytes they started from and redo to the bytes they left.
@(test)
strokes_undo_exactly :: proc(t: ^testing.T) {
	p := hills(100, 90, context.temp_allocator)
	h: editor.History
	defer editor.history_destroy(&h)
	start := snapshot(&p)

	b := editor.BRUSH_DEFAULT
	after: [dynamic]Snapshot
	after.allocator = context.temp_allocator
	strokes := [?]struct {
		mode:  editor.Brush_Mode,
		shape: editor.Brush_Shape,
		from:  [2]f32,
		to:    [2]f32,
	}{{.Lower, .Round, {10, 10}, {70, 40}}, {.Raise, .Rough, {50, 20}, {60, 80}}, {.Flatten, .Square, {31, 31}, {33, 64}}, {.Smooth, .Round, {0, 0}, {99, 89}}}
	for s in strokes {
		b.mode, b.shape, b.strength, b.target = s.mode, s.shape, 1, 30
		editor.history_begin(&h)
		for k in 0 ..= 20 {
			editor.brush_dab(&p, b, s.from + (s.to - s.from) * f32(k) / 20, 1, &h)
		}
		editor.history_end(&h)
		append(&after, snapshot(&p))
	}
	testing.expect(t, !same(&p, start), "the strokes changed nothing")

	for i := len(strokes) - 1; i >= 0; i -= 1 {
		_, ok := editor.history_undo(&h, &p)
		testing.expect(t, ok)
		want := i > 0 ? after[i - 1] : start
		testing.expectf(t, same(&p, want), "undoing stroke %d does not give back what it started from", i)
	}
	_, more := editor.history_undo(&h, &p)
	testing.expect(t, !more, "undid past the first stroke")
	for i in 0 ..< len(strokes) {
		editor.history_redo(&h, &p)
		testing.expectf(t, same(&p, after[i]), "redoing stroke %d does not give what it left", i)
	}

	// A new stroke after an undo leaves nothing to redo.
	editor.history_undo(&h, &p)
	editor.history_begin(&h)
	editor.brush_dab(&p, b, {50, 50}, 1, &h)
	editor.history_end(&h)
	_, redone := editor.history_redo(&h, &p)
	testing.expect(t, !redone, "redid over a new stroke")
}

// Past its budget, undo forgets the oldest strokes, and keeps the newest
// whatever it holds.
@(test)
undo_keeps_to_its_budget :: proc(t: ^testing.T) {
	p := hills(128, 96, context.temp_allocator) // whole tiles
	TILE_BYTES :: editor.TILE * editor.TILE * 8 // heights and water
	h := editor.History {
		budget = 3 * TILE_BYTES,
	}
	defer editor.history_destroy(&h)
	b := editor.BRUSH_DEFAULT
	b.radius = 4
	// One tile each, then one of four.
	for at in ([?][2]f32{{10, 10}, {45, 10}, {80, 10}, {32, 64}}) {
		editor.history_begin(&h)
		editor.brush_dab(&p, b, at, 1, &h)
		editor.history_end(&h)
	}
	testing.expect_value(t, h.bytes, 4 * TILE_BYTES)
	undone := 0
	for {
		if _, ok := editor.history_undo(&h, &p); !ok {
			break
		}
		undone += 1
	}
	testing.expect_value(t, undone, 1)
	testing.expect_value(t, h.bytes, 4 * TILE_BYTES)
}

// Lowered under the water, ground takes the level's water over it; raised
// out again, it has none.
@(test)
water_follows_the_ground :: proc(t: ^testing.T) {
	p := hills(40, 40, context.temp_allocator)
	for &v in p.heights {
		v = 12
	}
	h: editor.History
	defer editor.history_destroy(&h)
	b := editor.Brush {
		mode     = .Flatten,
		shape    = .Square,
		radius   = 6,
		strength = 1,
		falloff  = 0,
		target   = 4,
	}
	editor.brush_dab(&p, b, {20, 20}, 1, &h)
	i := 20 * 40 + 20
	testing.expect_value(t, p.heights[i], 4)
	c := p.level.water.colour
	testing.expect_value(t, [4]u8{p.water[i * 4], p.water[i * 4 + 1], p.water[i * 4 + 2], p.water[i * 4 + 3]}, [4]u8{c.r, c.g, c.b, 255})
	testing.expect_value(t, p.water[(2 * 40 + 2) * 4 + 3], 0)

	b.target = 15
	editor.brush_dab(&p, b, {20, 20}, 1, &h)
	testing.expect_value(t, p.heights[i], 15)
	testing.expect_value(t, [4]u8{p.water[i * 4], p.water[i * 4 + 1], p.water[i * 4 + 2], p.water[i * 4 + 3]}, [4]u8{})
}

// A change of the settings undoes and redoes as one.
@(test)
settings_undo :: proc(t: ^testing.T) {
	p := hills(8, 8, context.temp_allocator)
	h: editor.History
	defer editor.history_destroy(&h)
	before := editor.settings_of(&p)
	p.level.lighting.sun_azimuth_degrees = 200
	p.level.water.height = 3
	p.level.wind = {direction_degrees = 90, strength = 0.5}
	changed := editor.settings_of(&p)
	editor.history_settings(&h, before)
	c, ok := editor.history_undo(&h, &p)
	testing.expect(t, ok && c.settings && !c.map_)
	testing.expect_value(t, editor.settings_of(&p), before)
	editor.history_redo(&h, &p)
	testing.expect_value(t, editor.settings_of(&p), changed)
}

// The light copied as JSON pastes back the same; a whole level record's
// light pastes too, and a field left out keeps the measured value.
@(test)
lighting_json_round_trips :: proc(t: ^testing.T) {
	l := data.LIGHTING_MEASURED
	l.sun_azimuth_degrees, l.sun_colour, l.softness = 123.5, {250, 200, 150}, 2.25
	back, ok := editor.lighting_parse(editor.lighting_json(l, context.temp_allocator))
	testing.expect(t, ok)
	testing.expect_value(t, back, l)

	record, rok := editor.lighting_parse(`{"id": "le99", "lighting": {"sun_elevation_degrees": 25}}`)
	testing.expect(t, rok)
	want := data.LIGHTING_MEASURED
	want.sun_elevation_degrees = 25
	testing.expect_value(t, record, want)

	_, bad := editor.lighting_parse("not json")
	testing.expect(t, !bad)
	_, list := editor.lighting_parse("[1, 2]")
	testing.expect(t, !list)
}

// A zoom keeps the map's point under the cursor where it was, anywhere
// but against the map's ends, and stays within its limits. The map is wider
// than the view throughout: narrower, it is centred instead.
@(test)
zoom_keeps_the_point_under_the_cursor :: proc(t: ^testing.T) {
	p := terrain.project_make(1000, 3600, context.temp_allocator)
	area := editor.layout(1280, 900).view
	v := editor.View {
		zoom = 1,
		row  = 1500,
	}
	screen := [2]f32{area.x + 300, area.y + 200}
	for factor in ([?]f32{1.5, 1.1, 2, 0.5, 0.8, 1 / 1.1}) {
		at := editor.view_to_map(&v, &p, area, screen)
		editor.view_zoom_at(&v, &p, area, screen, factor)
		moved := editor.view_to_map(&v, &p, area, screen) - at
		testing.expectf(t, abs(moved.x) < 1e-2 && abs(moved.y) < 1e-2, "zoomed by %v to %v, the point under the cursor moved %v", factor, v.zoom, moved)
	}
	editor.view_zoom_at(&v, &p, area, screen, 100)
	testing.expect_value(t, v.zoom, f32(editor.ZOOM_MAX))
	editor.view_zoom_at(&v, &p, area, screen, 0.001)
	testing.expect_value(t, v.zoom, f32(editor.ZOOM_MIN))
	testing.expect_value(t, editor.view_rows(&v, area), area.height / editor.ZOOM_MIN)
	// Out at the top of the level, the scroll is held at its start.
	v.zoom, v.row = 2, 10
	editor.view_zoom_at(&v, &p, area, {area.x + 10, area.y + area.height - 10}, 0.5)
	testing.expect_value(t, v.row, 0)
}

// A motion's scroll axes, as XWayland's pointer has them (valuators 2
// and 3 after x and y), read as notches: the first value of each is where
// it is, and then each move is by its increment, down and right negative
// as GLFW's wheel has them. Another device's are not these.
@(test)
smooth_scroll_reads_the_axes :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux {
		g: editor.Gestures
		g.axes[0] = {device = 6, number = 2, horizontal = true, increment = 10}
		g.axes[1] = {device = 6, number = 3, increment = 120}
		g.count = 2
		motion :: proc(g: ^editor.Gestures, source: c.int, mask: u8, values: ..f64) -> [2]f32 {
			m := [1]u8{mask}
			return editor.gestures_motion(g, source, m[:], raw_data(values))
		}
		// Raw motion: the values are moves, x and y's too, which are not
		// scroll.
		testing.expect_value(t, motion(&g, 6, 0b0011, 5, 7), [2]f32{})
		testing.expect_value(t, motion(&g, 6, 0b1100, 0, 0), [2]f32{})
		testing.expect(t, !g.smooth, "smooth before an axis moved")
		testing.expect_value(t, motion(&g, 6, 0b1011, 5, 7, 60), [2]f32{0, -0.5})
		testing.expect(t, g.smooth, "not smooth once an axis moved")
		testing.expect_value(t, motion(&g, 6, 0b0100, -20), [2]f32{2, 0})
		testing.expect_value(t, motion(&g, 7, 0b1100, 30, 30), [2]f32{})
		testing.expect_value(t, motion(&g, 6, 0b1100, 10, -120), [2]f32{-1, 1})
	}
}

@(test)
editor_draws :: proc(t: ^testing.T) {
	rl.SetTraceLogLevel(.WARNING)
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(64, 64, "editor test")
	if !rl.IsWindowReady() {
		fmt.println("editor_draws: no display, skipped")
		return
	}
	defer rl.CloseWindow()
	os.make_directory_all(OUT)
	shot_shows_the_project(t)
	shot_zoomed(t)
	gestures_select(t)
	gestures_leave_glfw_the_pointer(t)
	stroke_and_undo_redraw(t)
	units_draw_on_the_map(t)
	materials_through_the_editor(t)
	models_through_the_editor(t)
	export_writes_a_plugin(t)
	le07_sculpt_relight_save_reopen(t)
}

// The editor's shot of a project is its panels, and in the viewport the
// terrain's own lit rows, the last screenful of the level first.
@(private = "file")
shot_shows_the_project :: proc(t: ^testing.T) {
	p := hills(120, 1000, context.temp_allocator)
	path :: OUT + "/hills.drproj.json"
	testing.expect(t, terrain.project_save(&p, path))
	e: editor.Editor
	editor.editor_init(&e)
	defer editor.editor_destroy(&e)
	if !testing.expect(t, editor.editor_open(&e, path)) {
		return
	}
	W, H :: 800, 600
	img := editor.editor_shot(&e, W, H)
	defer rl.UnloadImage(img)
	rl.ExportImage(img, OUT + "/shot.png")
	px := ([^]u8)(img.data)[:W * H * 3]

	l := editor.layout(W, H)
	rows := int(l.view.height)
	x0 := int(l.view.x) + (int(l.view.width) - 120) / 2
	from := 1000 - rows
	lit, ok := terrain.render(&e.renderer, &e.project, {output = .Lit, from = from, to = 1000}, context.temp_allocator)
	if !testing.expect(t, ok) {
		return
	}
	differ := 0
	for y in 0 ..< rows {
		for x in 0 ..< 120 {
			for c in 0 ..< 3 {
				if px[(y * W + x0 + x) * 3 + c] != lit.pixels[(y * 120 + x) * 3 + c] {
					differ += 1
				}
			}
		}
	}
	testing.expectf(t, differ == 0, "the viewport differs from the terrain's render in %d values", differ)

	// The panel has something drawn on it: not all its background.
	first := px[(10 * W + 10) * 3:][:3]
	varied := false
	for y in 0 ..< int(l.panel.height) {
		for x in 0 ..< int(l.panel.width) {
			if string(px[(y * W + x) * 3:][:3]) != string(first) {
				varied = true
			}
		}
	}
	testing.expect(t, varied, "the panel is blank")
}

// Zoomed out, a short level is drawn its own height and no more, the view's
// background below it; zoomed in between the presets, the view is full.
@(private = "file")
shot_zoomed :: proc(t: ^testing.T) {
	p := hills(120, 300, context.temp_allocator)
	path :: OUT + "/zoomed.drproj.json"
	testing.expect(t, terrain.project_save(&p, path))
	e: editor.Editor
	editor.editor_init(&e)
	defer editor.editor_destroy(&e)
	if !testing.expect(t, editor.editor_open(&e, path)) {
		return
	}
	W, H :: 800, 600
	l := editor.layout(W, H)
	background :: [3]u8{24, 26, 30}
	for zoom in ([?]f32{0.5, 1.5}) {
		e.zoom = zoom
		img := editor.editor_shot(&e, W, H)
		defer rl.UnloadImage(img)
		rl.ExportImage(img, fmt.ctprintf("%s/zoomed-%.0f.png", OUT, zoom * 100))
		px := ([^]u8)(img.data)[:W * H * 3]
		at :: proc(px: []u8, x, y: int) -> [3]u8 {
			c := px[(y * W + x) * 3:][:3]
			return {c[0], c[1], c[2]}
		}
		// Along the view's middle column, the map's rows and then any below.
		x := int(l.view.x + l.view.width / 2)
		shown := min(int(l.view.height), int(300 * zoom))
		ground, below := 0, 0
		for y in int(l.view.y) ..< int(l.view.y + l.view.height) {
			c := at(px, x, y)
			if y - int(l.view.y) < shown - 1 {
				ground += c != background ? 1 : 0
			} else if y - int(l.view.y) > shown {
				below += c != background ? 1 : 0
			}
		}
		testing.expectf(t, ground == shown - 1, "at %v the level shows in %d of its %d rows", zoom, ground, shown - 1)
		testing.expectf(t, below == 0, "at %v %d rows below the level are drawn", zoom, below)
	}
}

// The overview's box is the view's part of the map, across as well as
// along: the whole width when the map fits, a slice of it panned when
// zoomed in.
@(test)
overview_box_follows_the_pan :: proc(t: ^testing.T) {
	p := terrain.Project {
		width  = 480,
		length = 3600,
	}
	l := editor.layout(1280, 900)
	s, r := editor.overview_fit(&p, l.overview)
	v := editor.View {
		zoom = 1,
		row  = 1000,
	}
	near :: proc(a, b: f32) -> bool {return abs(a - b) < 0.01}
	b := editor.overview_box(&v, &p, l.view, s, r)
	testing.expectf(t, near(b.x, r.x) && near(b.width, r.width), "fitting, the box %v, the map %v", b, r)
	testing.expectf(t, near(b.y, r.y + 1000 * s) && near(b.height, l.view.height * s), "fitting, the box %v", b)
	v.zoom, v.left = 4, 200
	b = editor.overview_box(&v, &p, l.view, s, r)
	testing.expectf(t, near(b.x, r.x + 200 * s) && near(b.width, l.view.width / 4 * s), "zoomed in, the box %v, the map %v", b, r)
	testing.expectf(t, near(b.height, l.view.height / 4 * s), "zoomed in, the box %v", b)
	testing.expect(t, b.x + b.width <= r.x + r.width + 0.01, "the box past the map's right")
}

// Under X (xvfb-run's has XInput 2.4), the pinch and the raw motion are
// selected, and with no touchpad there is neither a pinch nor a scroll.
@(private = "file")
gestures_select :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux {
		if lib, ok := dynlib.load_library("libXi.so.6"); ok {
			dynlib.unload_library(lib)
		} else {
			fmt.println("gestures_select: no libXi, skipped")
			return
		}
		g: editor.Gestures
		defer editor.gestures_destroy(&g)
		if testing.expect(t, editor.gestures_init(&g), "no gestures under X with libXi") {
			testing.expect_value(t, editor.gestures_poll(&g), editor.Gesture_Input{zoom = 1})
		}
	}
}

// With the gestures selected, GLFW still sees the pointer: the server
// gives a pointer's event on a window to one selection, XI2's first, and
// XI_Motion selected on GLFW's window once took its motion, so raylib's
// mouse stood still and raygui's buttons went dead. The window is shown
// and the pointer warped onto it, on Xvfb only (DR_XVFB, from mise's
// test): never the desktop's pointer.
@(private = "file")
gestures_leave_glfw_the_pointer :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux {
		if os.get_env("DR_XVFB", context.temp_allocator) == "" {
			fmt.println("gestures_leave_glfw_the_pointer: not on Xvfb, skipped")
			return
		}
		X :: struct {
			__handle:      dynlib.Library,
			XOpenDisplay:  proc "c" (name: cstring) -> rawptr,
			XCloseDisplay: proc "c" (d: rawptr) -> c.int,
			XWarpPointer:  proc "c" (d: rawptr, src, dest: c.ulong, sx, sy: c.int, sw, sh: c.uint, dx, dy: c.int) -> c.int,
			XSync:         proc "c" (d: rawptr, discard: b32) -> c.int,
		}
		x: X
		if n, _ := dynlib.initialize_symbols(&x, "libX11.so.6"); n != size_of(X) / size_of(rawptr) - 1 {
			fmt.println("gestures_leave_glfw_the_pointer: no libX11, skipped")
			return
		}
		defer dynlib.unload_library(x.__handle)
		display := x.XOpenDisplay(nil)
		if !testing.expect(t, display != nil) {
			return
		}
		defer x.XCloseDisplay(display)
		g: editor.Gestures
		defer editor.gestures_destroy(&g)
		if !editor.gestures_init(&g) {
			return // gestures_select says why
		}
		rl.ClearWindowState({.WINDOW_HIDDEN})
		defer rl.SetWindowState({.WINDOW_HIDDEN})
		window := (cast(^c.ulong)rl.GetWindowHandle())^
		for to in ([?][2]c.int{{20, 30}, {41, 12}}) {
			seen := false
			// Mapping the window, and the warp's events, take a moment.
			for _ in 0 ..< 100 {
				x.XWarpPointer(display, 0, window, 0, 0, 0, 0, to.x, to.y)
				x.XSync(display, false)
				rl.PollInputEvents()
				editor.gestures_poll(&g)
				if rl.GetMousePosition() == {f32(to.x), f32(to.y)} {
					seen = true
					break
				}
				time.sleep(10 * time.Millisecond)
			}
			testing.expectf(t, seen, "the pointer at %v, raylib's at %v", to, rl.GetMousePosition())
		}
		testing.expect(t, rl.IsCursorOnScreen(), "GLFW was not told the pointer came in")
	}
}

// A stroke through the editor draws as the project drawn afresh, and its
// undo as the project before it.
@(private = "file")
stroke_and_undo_redraw :: proc(t: ^testing.T) {
	p := hills(90, 80, context.temp_allocator)
	path :: OUT + "/stroke.drproj.json"
	testing.expect(t, terrain.project_save(&p, path))
	e: editor.Editor
	editor.editor_init(&e)
	defer editor.editor_destroy(&e)
	if !testing.expect(t, editor.editor_open(&e, path)) {
		return
	}
	fresh :: proc(t: ^testing.T, p: ^terrain.Project) -> string {
		r: terrain.Renderer
		testing.expect(t, terrain.renderer_init(&r, p))
		defer terrain.renderer_destroy(&r)
		pic, _ := terrain.render(&r, p, {output = .Lit}, context.temp_allocator)
		return string(pic.pixels)
	}
	drawn :: proc(e: ^editor.Editor) -> string {
		pic, _ := terrain.render(&e.renderer, &e.project, {output = .Lit}, context.temp_allocator)
		return string(pic.pixels)
	}
	before := drawn(&e)
	e.brush.mode, e.brush.strength = .Lower, 1
	editor.editor_stroke_begin(&e, {20, 20})
	editor.editor_stroke_to(&e, {70, 60}, 3)
	editor.editor_stroke_end(&e)
	testing.expect(t, e.dirty)
	after := drawn(&e)
	testing.expect(t, after != before, "the stroke drew nothing")
	testing.expect(t, after == fresh(t, &e.project), "the stroke draws otherwise than a fresh upload")
	testing.expect(t, editor.editor_undo(&e))
	testing.expect(t, drawn(&e) == before, "the undo draws otherwise than before the stroke")
	testing.expect(t, editor.editor_redo(&e))
	testing.expect(t, drawn(&e) == after, "the redo draws otherwise than after the stroke")
}

// Stage 7's exit: open le07's recovered project, sculpt, relight, save and
// open it again, to find it as it was left.
@(private = "file")
le07_sculpt_relight_save_reopen :: proc(t: ^testing.T) {
	if !os.exists(LE07) {
		fmt.println("le07_sculpt_relight_save_reopen: no", LE07, "(mise run terrain:recover), skipped")
		return
	}
	e: editor.Editor
	editor.editor_init(&e)
	defer editor.editor_destroy(&e)
	if !testing.expect(t, editor.editor_open(&e, LE07)) {
		return
	}
	for mode in editor.Brush_Mode {
		e.brush.mode = mode
		editor.editor_stroke_begin(&e, {100, 1500 + 40 * f32(mode)})
		editor.editor_stroke_to(&e, {380, 1540 + 40 * f32(mode)}, 4)
		editor.editor_stroke_end(&e)
	}
	e.project.level.lighting.sun_azimuth_degrees = 300
	e.project.level.lighting.ambient = 0.3
	editor.editor_settings_settle(&e, false)
	e.project.level.wind = {direction_degrees = 45, strength = 0.25}
	editor.editor_settings_settle(&e, false)

	path :: OUT + "/le07.drproj.json"
	if !testing.expect(t, editor.editor_save(&e, path)) {
		return
	}
	testing.expect(t, !e.dirty)
	heights := make([]f32, len(e.project.heights), context.temp_allocator)
	copy(heights, e.project.heights)
	water := make([]u8, len(e.project.water), context.temp_allocator)
	copy(water, e.project.water)
	level := e.project.level
	// Deep: the strings are the project's, freed when it is opened again.
	placements := slice.clone(e.project.placements[:], context.temp_allocator)
	for &pl in placements {
		pl.unit, pl.layer = strings.clone(pl.unit, context.temp_allocator), strings.clone(pl.layer, context.temp_allocator)
	}
	testing.expect_value(t, len(placements), 38)

	if !testing.expect(t, editor.editor_open(&e, path)) {
		return
	}
	testing.expect_value(t, e.project.level.lighting, level.lighting)
	testing.expect_value(t, e.project.level.wind, level.wind)
	testing.expect_value(t, e.project.level.water, level.water)
	testing.expect(t, slice.equal(e.project.placements[:], placements), "the units came back otherwise")
	testing.expect(t, string(e.project.water) == string(water), "the water layer came back otherwise")
	for v, i in heights {
		if f32(terrain.height_quantise(v)) * terrain.HEIGHT_UNIT != e.project.heights[i] {
			testing.expectf(t, false, "height %d: %v saved, %v opened", i, v, e.project.heights[i])
			break
		}
	}
	// And the editor can still undo nothing: a project opened is new.
	testing.expect(t, !editor.editor_undo(&e))
}
