package editor_tests

// Materials and the level's properties (Stage 8): the paint brush, its
// undo, the library, and through the editor, materials added, painted,
// taken away, undone, saved and opened again.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import rl "vendor:raylib"

import "dr:editor"
import "dr:terrain"

// Two materials over hills, and no weights yet.
@(private = "file")
two_materials :: proc(w, l: int) -> terrain.Project {
	p := hills(w, l, context.temp_allocator)
	append(&p.materials, terrain.Material{name = "sand", colour = {200, 180, 120}})
	append(&p.materials, terrain.Material{name = "rock", colour = {90, 90, 96}})
	return p
}

// A library of one material, stripes 32 pixels across, under OUT/library.
@(private = "file")
LIBRARY :: OUT + "/library"

@(private = "file")
library_fixture :: proc(t: ^testing.T) -> terrain.Picture {
	dir :: LIBRARY + "/materials"
	os.make_directory_all(dir)
	stripes := terrain.picture_make(32, 32, 3, 8, context.temp_allocator)
	for y in 0 ..< 32 {
		for x in 0 ..< 32 {
			px := stripes.pixels[(y * 32 + x) * 3:][:3]
			px[0], px[1], px[2] = u8(x / 4 % 2 * 200 + 40), 90, u8(y * 6)
		}
	}
	testing.expect(t, terrain.png_write(dir + "/stripes.png", stripes))
	index := `{"format": "deimos-rising.material-library", "materials": [
		{"name": "stripes", "image": "stripes.png", "colour": [255, 255, 255], "tile": 32, "tags": ["original-derived"], "source": "test"}]}`
	testing.expect(t, os.write_entire_file(dir + "/index.json", transmute([]u8)index) == nil)
	return stripes
}

// Painting moves every weight toward the material, to all of it where the
// brush is held; the weights never sum past full; erasing takes it away;
// and nothing outside the brush changes.
@(test)
paint_moves_the_weights :: proc(t: ^testing.T) {
	p := two_materials(64, 64)
	splat := terrain.project_splat(&p, context.temp_allocator)
	for i in 0 ..< 64 * 64 {
		splat[i * 4] = 200
	}
	h: editor.History
	defer editor.history_destroy(&h)
	b := editor.BRUSH_DEFAULT
	b.radius, b.strength = 10, 1
	for _ in 0 ..< 40 {
		editor.paint_dab(&p, b, .Paint, 1, {32, 32}, 1, &h)
	}
	centre := splat[(32 * 64 + 32) * 4:][:4]
	testing.expect_value(t, [4]u8{centre[0], centre[1], centre[2], centre[3]}, [4]u8{0, 255, 0, 0})
	for i in 0 ..< 64 * 64 {
		px := splat[i * 4:][:4]
		if int(px[0]) + int(px[1]) + int(px[2]) + int(px[3]) > 255 {
			testing.expectf(t, false, "the weights at %d sum past full", i)
			break
		}
	}
	far := splat[(2 * 64 + 2) * 4:][:4]
	testing.expect_value(t, [4]u8{far[0], far[1], far[2], far[3]}, [4]u8{200, 0, 0, 0})
	for _ in 0 ..< 40 {
		editor.paint_dab(&p, b, .Erase, 1, {32, 32}, 1, &h)
	}
	testing.expect_value(t, splat[(32 * 64 + 32) * 4 + 1], 0)
	testing.expect_value(t, editor.paint_dab(&p, b, .Paint, 5, {32, 32}, 1, &h), terrain.Rect{})
}

// A painted stroke undoes to the weights it started from, and redoes to
// those it left.
@(test)
paint_undoes_exactly :: proc(t: ^testing.T) {
	p := two_materials(80, 70)
	splat := terrain.project_splat(&p, context.temp_allocator)
	start := strings.clone(string(splat), context.temp_allocator)
	h: editor.History
	defer editor.history_destroy(&h)
	b := editor.BRUSH_DEFAULT
	b.shape, b.radius = .Rough, 20
	editor.history_begin(&h)
	for k in 0 ..< 12 {
		editor.paint_dab(&p, b, .Paint, k % 2, {f32(5 + 6 * k), f32(10 + 4 * k)}, 1, &h)
	}
	editor.history_end(&h)
	painted := strings.clone(string(splat), context.temp_allocator)
	testing.expect(t, painted != start, "the stroke painted nothing")
	c, ok := editor.history_undo(&h, &p)
	testing.expect(t, ok && c.map_)
	testing.expect(t, string(splat) == start, "the undo left the weights otherwise")
	editor.history_redo(&h, &p)
	testing.expect(t, string(splat) == painted, "the redo left the weights otherwise")
}

// A material's look, the rules and the level's properties are settings,
// undone as one.
@(test)
looks_and_properties_undo :: proc(t: ^testing.T) {
	p := two_materials(8, 8)
	p.level.name = "Before"
	h: editor.History
	defer editor.history_destroy(&h)
	before := editor.settings_of(&p)
	p.materials[1].colour, p.materials[1].tile = {1, 2, 3}, 99
	p.cliff = {material = 1, from = 0.5, to = 1}
	p.level.name, p.level.start_weapons.air = "After", "aipb"
	changed := editor.settings_of(&p)
	testing.expect(t, changed != before)
	editor.history_settings(&h, before)
	editor.history_undo(&h, &p)
	testing.expect_value(t, p.materials[1].colour, [3]u8{90, 90, 96})
	testing.expect_value(t, p.cliff.material, -1)
	testing.expect_value(t, p.level.name, "Before")
	testing.expect_value(t, p.level.start_weapons.air, "")
	editor.history_redo(&h, &p)
	testing.expect_value(t, editor.settings_of(&p), changed)
}

// Every property the Level tab edits is saved and read back.
@(test)
properties_save_and_reopen :: proc(t: ^testing.T) {
	os.make_directory_all(OUT)
	p := terrain.project_make(8, 8, context.temp_allocator)
	want: editor.Properties
	for f in editor.Field {
		want.text[f] = fmt.tprintf("text %d", int(f))
	}
	want.start_air, want.start_ground = "aipb", "grbm"
	editor.properties_set(&p, want)
	path :: OUT + "/properties.drproj.json"
	testing.expect(t, terrain.project_save(&p, path))
	q, ok := terrain.project_load(path, context.temp_allocator)
	if testing.expect(t, ok) {
		testing.expect_value(t, editor.properties_of(&q), want)
	}
}

// A library is read from its index, and the one in the assets tree, when
// there is one, is whole: every image there and tiling at 256.
@(test)
library_loads :: proc(t: ^testing.T) {
	library_fixture(t)
	l: editor.Library
	defer editor.library_destroy(&l)
	testing.expect(t, editor.library_load(&l, LIBRARY))
	if testing.expect_value(t, len(l.entries), 1) {
		testing.expect_value(t, l.entries[0].name, "stripes")
		testing.expect_value(t, l.entries[0].tile, f32(32))
		testing.expect_value(t, l.entries[0].tags[0], "original-derived")
	}
	testing.expect(t, !editor.library_load(&l, OUT + "/nowhere"))

	assets: editor.Library
	defer editor.library_destroy(&assets)
	if !editor.library_load(&assets, "assets") {
		fmt.println("library_loads: no assets/materials (mise run materials:library), skipped")
		return
	}
	testing.expect(t, len(assets.entries) > 0)
	for en in assets.entries {
		pic, ok := terrain.picture_load(strings.concatenate({assets.dir, "/", en.image}, context.temp_allocator), 3, context.temp_allocator)
		testing.expectf(t, ok && pic.width == 256 && pic.height == 256, "%s: %s is not a 256 x 256 image", en.name, en.image)
		testing.expectf(t, len(en.tags) > 0 && en.tags[0] == "original-derived", "%s is not tagged original-derived", en.name)
	}
}

// Through the editor: a library material and a dropped image added, a
// stroke painted, drawn as a fresh upload draws it; a material taken away
// and that undone; saved with its images beside, and opened again the same.
materials_through_the_editor :: proc(t: ^testing.T) {
	stripes := library_fixture(t)
	testing.expect(t, terrain.png_write(OUT + "/Rock Face.png", stripes))

	e: editor.Editor
	editor.editor_init(&e)
	defer editor.editor_destroy(&e)
	path :: OUT + "/painted/painted.drproj.json"
	os.make_directory_all(OUT + "/painted")
	if !testing.expect(t, editor.editor_new(&e, 200, path)) {
		return
	}
	testing.expect(t, editor.library_load(&e.library, LIBRARY))
	testing.expect(t, editor.editor_material_add_library(&e, &e.library, 0))
	testing.expect(t, editor.editor_material_add_file(&e, OUT + "/Rock Face.png"))
	testing.expect(t, !editor.editor_material_add_file(&e, OUT + "/no such.png"))
	if !testing.expect_value(t, len(e.project.materials), 3) {
		return
	}
	testing.expect_value(t, e.project.materials[1].image, "materials/stripes.png")
	testing.expect_value(t, e.project.materials[2].name, "rock-face")
	testing.expect_value(t, e.project.materials[2].image, "materials/rock-face.png")
	testing.expect_value(t, e.project.materials[2].tile, f32(32))

	drawn :: proc(e: ^editor.Editor) -> string {
		pic, _ := terrain.render(&e.renderer, &e.project, {output = .Lit}, context.temp_allocator)
		return string(pic.pixels)
	}
	fresh :: proc(t: ^testing.T, p: ^terrain.Project) -> string {
		r: terrain.Renderer
		testing.expect(t, terrain.renderer_init(&r, p))
		defer terrain.renderer_destroy(&r)
		pic, _ := terrain.render(&r, p, {output = .Lit}, context.temp_allocator)
		return string(pic.pixels)
	}
	before := drawn(&e)
	e.tab = i32(editor.Tab.Paint)
	e.brush.strength = 1
	for m in 1 ..= 2 {
		e.paint.material = m
		editor.editor_stroke_begin(&e, {60, f32(40 + 60 * (m - 1))})
		editor.editor_stroke_to(&e, {420, f32(80 + 60 * (m - 1))}, 6)
		editor.editor_stroke_end(&e)
	}
	painted := drawn(&e)
	testing.expect(t, painted != before, "the strokes painted nothing")
	testing.expect(t, painted == fresh(t, &e.project), "the paint draws otherwise than a fresh upload")
	shot := editor.editor_shot(&e, 1000, 700)
	rl.ExportImage(shot, OUT + "/painted.png")
	rl.UnloadImage(shot)

	// Taking the stripes away moves the rock's weights down to its place.
	weights := strings.clone(string(e.project.splat), context.temp_allocator)
	editor.editor_material_remove(&e, 1)
	testing.expect_value(t, len(e.project.materials), 2)
	testing.expect_value(t, e.project.materials[1].name, "rock-face")
	moved := 0
	for i in 0 ..< e.project.width * e.project.length {
		if e.project.splat[i * 4 + 1] != weights[i * 4 + 2] || e.project.splat[i * 4 + 2] != 0 {
			moved += 1
		}
	}
	testing.expectf(t, moved == 0, "%d weights are not where the removal leaves them", moved)
	testing.expect(t, drawn(&e) == fresh(t, &e.project), "the removal draws otherwise than a fresh upload")
	testing.expect(t, editor.editor_undo(&e))
	testing.expect_value(t, len(e.project.materials), 3)
	testing.expect(t, string(e.project.splat) == weights, "the undone removal left the weights otherwise")
	testing.expect(t, drawn(&e) == painted, "the undone removal draws otherwise than before it")

	testing.expect(t, editor.editor_save(&e, path))
	testing.expect(t, os.exists(OUT + "/painted/materials/stripes.png"))
	testing.expect(t, os.exists(OUT + "/painted/materials/rock-face.png"))
	testing.expect(t, editor.editor_open(&e, path))
	testing.expect_value(t, len(e.project.materials), 3)
	testing.expect(t, string(e.project.splat) == weights, "the weights came back otherwise")
	testing.expect(t, drawn(&e) == painted, "the project opened again draws otherwise")
}
