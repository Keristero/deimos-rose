package editor_tests

// Scenery models (Stage 8): the library and the profiles read and kept,
// and through the editor, a profile's brush scattering models as its
// spacing, density and chances say, erased, edited, undone, imported,
// saved and opened again.

import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"

import "dr:editor"
import "dr:terrain"

// A library of two files under OUT/model-library/models: "bushes", a
// small and a big box, and "rock", one; and one profile of them.
@(private = "file")
MODEL_LIBRARY :: OUT + "/model-library"

@(private = "file")
box :: proc(name: string, lo, hi: [3]f32) -> terrain.Model_Mesh {
	m := terrain.Model_Mesh {
		name = name,
		lo   = lo,
		hi   = hi,
	}
	positions := make([dynamic][3]f32, context.temp_allocator)
	normals := make([dynamic][3]f32, context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)
	// Each face its own four corners, so its normal is its own.
	for axis in 0 ..< 3 {
		for side in 0 ..< 2 {
			n: [3]f32
			n[axis] = side == 0 ? -1 : 1
			u, v := (axis + 1) % 3, (axis + 2) % 3
			base := u32(len(positions))
			for corner in 0 ..< 4 {
				p: [3]f32
				p[axis] = side == 0 ? lo[axis] : hi[axis]
				p[u] = corner & 1 == 0 ? lo[u] : hi[u]
				p[v] = corner & 2 == 0 ? lo[v] : hi[v]
				append(&positions, p)
				append(&normals, n)
			}
			append(&indices, base, base + 1, base + 3, base, base + 3, base + 2)
		}
	}
	m.positions, m.normals, m.indices = positions[:], normals[:], indices[:]
	m.uvs = make([][2]f32, len(positions), context.temp_allocator)
	m.parts = make([]terrain.Model_Part, 1, context.temp_allocator)
	m.parts[0] = {first = 0, count = len(indices), image = -1, colour = {0.2, 0.6, 0.2, 1}}
	return m
}

@(private = "file")
model_library_fixture :: proc(t: ^testing.T) {
	dir :: MODEL_LIBRARY + "/models"
	dir_make(dir)
	bushes := terrain.Model_File {
		name     = "bushes",
		variants = {box("small", {-1, 0, -1}, {1, 1, 1}), box("big", {-2, 0, -2}, {2, 3, 2})},
	}
	rock := terrain.Model_File {
		name     = "rock",
		variants = {box("rock", {-1, 0, -1}, {1, 0.5, 1})},
	}
	testing.expect(t, terrain.model_file_write(dir + "/bushes.glb", bushes))
	testing.expect(t, terrain.model_file_write(dir + "/rock.glb", rock))
	index := `{"format": "deimos-rising.model-library", "models": [
		{"file": "bushes", "tags": ["shrub"], "source": "test"},
		{"file": "rock", "tags": ["rock"], "source": "test"},
		{"file": "../escape", "tags": [], "source": "test"}]}`
	testing.expect(t, os.write_entire_file(dir + "/index.json", transmute([]u8)index) == nil)
	profiles := `{"format": "deimos-rising.brush-profiles", "profiles": [
		{"name": "Scrub", "spacing": 6, "density": 1, "turn": [0, 360], "lean": [0, 0], "max_slope": 30, "dry": true,
		 "entries": [
			{"model": "bushes", "variant": "", "chance": 3, "scale": [1, 2], "offset": [0, 0]},
			{"model": "rock", "variant": "rock", "chance": 1, "scale": [1, 1], "offset": [-1, -1]}]}]}`
	testing.expect(t, os.write_entire_file(dir + "/profiles.json", transmute([]u8)profiles) == nil)
}

// A user's editor data of their own, empty.
@(private = "file")
user_dir :: proc(name: string) -> string {
	dir := fmt.tprintf("%s/%s", OUT, name)
	os.remove_all(dir)
	dir_make(dir)
	return dir
}

// The library reads its index's files, not one whose name is not a model
// name; the profiles read theirs; a user's profile saved is read again in
// the library's place where it has its name, and the library's others
// after it.
@(test)
library_and_profiles_load :: proc(t: ^testing.T) {
	model_library_fixture(t)
	s: editor.Scenery
	editor.scenery_init(&s)
	defer editor.scenery_destroy(&s)
	s.user_dir = user_dir("user-profiles")
	testing.expect_value(t, editor.model_library_load(&s, MODEL_LIBRARY), 2)
	testing.expect_value(t, s.library[0].file.name, "bushes")
	if testing.expect_value(t, len(s.library[0].file.variants), 2) {
		testing.expect_value(t, s.library[0].file.variants[1].name, "big")
		testing.expect_value(t, s.library[0].file.variants[1].hi, [3]f32{2, 3, 2})
	}
	testing.expect_value(t, s.library[1].tags[0], "rock")
	testing.expect_value(t, editor.profiles_load(&s, MODEL_LIBRARY), 1)
	pr := s.profiles[0]
	testing.expect_value(t, pr.name, "Scrub")
	testing.expect_value(t, len(pr.entries), 2)
	testing.expect_value(t, pr.entries[1].offset, [2]f32{-1, -1})

	s.profiles[0].spacing = 9
	testing.expect(t, editor.profile_add(&s, 0, "Scrub Copy") == 1)
	testing.expect(t, editor.profiles_save(&s))
	testing.expect(t, !s.profiles_dirty)

	again: editor.Scenery
	editor.scenery_init(&again)
	defer editor.scenery_destroy(&again)
	again.user_dir = s.user_dir
	testing.expect_value(t, editor.profiles_load(&again, MODEL_LIBRARY), 2)
	testing.expect_value(t, again.profiles[0].name, "Scrub")
	testing.expect_value(t, again.profiles[0].spacing, f32(9))
	testing.expect_value(t, again.profiles[1].name, "Scrub Copy")
	testing.expect_value(t, len(again.profiles[1].entries), 2)
}

// The library in the assets tree, when there is one, is whole: every
// model read, under the triangle budget, credited, and every profile's
// models in it.
@(test)
assets_model_library_loads :: proc(t: ^testing.T) {
	s: editor.Scenery
	editor.scenery_init(&s)
	defer editor.scenery_destroy(&s)
	s.user_dir = ""
	if editor.model_library_load(&s, "assets") == 0 {
		fmt.println("assets_model_library_loads: no assets/models (mise run models:library), skipped")
		return
	}
	for m in s.library {
		testing.expectf(t, terrain.file_triangles(m.file) <= terrain.MODEL_TRIANGLES, "%s is over the budget", m.file.name)
		testing.expectf(t, m.source != "", "%s has no source", m.file.name)
	}
	testing.expect(t, editor.profiles_load(&s, "assets") > 0)
	for pr in s.profiles {
		for en in pr.entries {
			testing.expectf(t, editor.library_find(&s, en.model) >= 0, "%s: %s is not in the library", pr.name, en.model)
		}
	}
}

// Through the editor (with GL): the profile's brush scatters as its
// spacing and density say, none under the water, its entries by their
// chances and either of an "any" entry's models; the scatter draws as a
// fresh upload does, undoes and redoes; the eraser takes the brush's
// circle; an instance edited and deleted undoes; an imported model is
// kept in the user's data; and the project saved opens again the same.
models_through_the_editor :: proc(t: ^testing.T) {
	model_library_fixture(t)
	e: editor.Editor
	editor.editor_init(&e)
	defer editor.editor_destroy(&e)
	s := &e.scenery
	s.user_dir = user_dir("user-models")
	testing.expect_value(t, editor.model_library_load(s, MODEL_LIBRARY), 2)
	testing.expect_value(t, editor.profiles_load(s, MODEL_LIBRARY), 1)
	path :: OUT + "/scattered/scattered.drproj.json"
	os.remove_all(OUT + "/scattered")
	dir_make(OUT + "/scattered")
	if !testing.expect(t, editor.editor_new(&e, 300, path)) {
		return
	}
	p := &e.project
	e.tab = i32(editor.Tab.Models)
	s.mode, s.profile = i32(editor.Models_Mode.Scatter), 0
	e.brush.radius = 30
	centre := [2]f32{240, 150}

	// Under the water, nothing.
	dry := p.level.water.height
	p.level.water.height = 100
	editor.editor_stroke_begin(&e, centre)
	editor.editor_stroke_end(&e)
	testing.expect_value(t, len(p.instances), 0)
	testing.expect(t, !editor.editor_undo(&e), "a stroke that put nothing down was recorded")
	p.level.water.height = dry

	editor.editor_stroke_begin(&e, centre)
	editor.editor_stroke_end(&e)
	fits: f32 = editor.JAMMED * math.PI * 30 * 30 / 36
	want := int(fits + 0.5)
	n := len(p.instances)
	// Sequential packing slows near the jam: SCATTER_TRIES a missing one
	// gets most of the way.
	testing.expectf(t, n >= want * 8 / 10 && n <= want, "%d instances for a dab that wants %d", n, want)
	kinds: [3]int // small, big, rock
	for i, k in p.instances {
		d := [2]f32{i.x, i.y} - centre
		testing.expectf(t, d.x * d.x + d.y * d.y <= 30 * 30, "instance %d is outside the brush", k)
		for j in p.instances[k + 1:] {
			dj := [2]f32{i.x - j.x, i.y - j.y}
			if dj.x * dj.x + dj.y * dj.y < 36 {
				testing.expectf(t, false, "instance %d is within the spacing of another", k)
				break
			}
		}
		m := p.models[i.model]
		switch {
		case m.file == "rock":
			kinds[2] += 1
			testing.expect_value(t, i.offset, f32(-1))
		case m.variant == 0:
			kinds[0] += 1
		case:
			kinds[1] += 1
		}
		testing.expect(t, i.scale >= 1 && i.scale <= 2 && i.turn >= 0 && i.turn < 360)
	}
	testing.expectf(t, kinds[0] > 0 && kinds[1] > 0 && kinds[0] + kinds[1] > kinds[2] * 3 / 2, "bushes small, big and rocks: %v", kinds)
	testing.expect_value(t, len(p.models), 3)
	testing.expect_value(t, len(p.model_files), 2)
	testing.expect_value(t, p.models[0].source, "test")

	// Another dab where it is full puts none more.
	editor.editor_stroke_begin(&e, centre)
	editor.editor_stroke_end(&e)
	testing.expect(t, len(p.instances) <= want)

	scattered := drawn(&e)
	placed := make([]terrain.Instance, len(p.instances), context.temp_allocator)
	copy(placed, p.instances[:])
	testing.expect(t, scattered == fresh(t, p), "the scatter draws otherwise than a fresh upload")
	for editor.editor_undo(&e) {}
	testing.expect_value(t, len(p.instances), 0)
	testing.expect(t, drawn(&e) != scattered, "the undone scatter still draws")
	for editor.editor_redo(&e) {}
	testing.expect(t, len(p.instances) == len(placed) && string(drawn(&e)) == scattered, "the redone scatter is otherwise")

	// The eraser takes the profile's in its circle, and no more.
	s.mode = i32(editor.Models_Mode.Erase)
	e.brush.radius = 12
	editor.editor_stroke_begin(&e, centre)
	editor.editor_stroke_end(&e)
	for i in p.instances {
		d := [2]f32{i.x, i.y} - centre
		testing.expect(t, d.x * d.x + d.y * d.y > 12 * 12, "the eraser left one in its circle")
	}
	testing.expect(t, len(p.instances) < len(placed))
	testing.expect(t, editor.editor_undo(&e))
	testing.expect_value(t, len(p.instances), len(placed))

	// Picked, lifted, deleted, and both undone.
	s.mode = i32(editor.Models_Mode.Select)
	k := editor.instance_pick(&e, {placed[0].x, placed[0].y})
	testing.expect(t, k >= 0)
	if k >= 0 {
		to := p.instances[k]
		to.offset, to.turn = 7, 45
		editor.editor_instance_set(&e, k, to)
		editor.instances_settle(&e, false)
		testing.expect_value(t, p.instances[k], to)
		editor.editor_instance_delete(&e, k)
		testing.expect_value(t, len(p.instances), len(placed) - 1)
		testing.expect(t, editor.editor_undo(&e))
		testing.expect_value(t, p.instances[k], to)
		testing.expect(t, editor.editor_undo(&e))
		testing.expect_value(t, p.instances[k], placed[k])
	}
	testing.expect(t, drawn(&e) == scattered, "the undone edits draw otherwise")

	// An import is kept in the user's data, and read again with the
	// library.
	obj := "v -1 0 -1\nv 1 0 -1\nv 0 2 0\nf 1 2 3\n"
	testing.expect(t, os.write_entire_file(OUT + "/Big Rock.obj", transmute([]u8)obj) == nil)
	testing.expect_value(t, editor.editor_model_import(&e, OUT + "/Big Rock.obj"), 2)
	testing.expect_value(t, editor.editor_model_import(&e, OUT + "/Big Rock.obj"), 3)
	testing.expect_value(t, s.library[3].file.name, "big-rock-2")
	testing.expect(t, os.exists(fmt.tprintf("%s/models/big-rock.glb", s.user_dir)))
	testing.expect_value(t, editor.editor_model_import(&e, OUT + "/no such.obj"), -1)
	again: editor.Scenery
	editor.scenery_init(&again)
	defer editor.scenery_destroy(&again)
	again.user_dir = s.user_dir
	testing.expect_value(t, editor.model_library_load(&again, MODEL_LIBRARY), 4)
	testing.expect(t, again.library[2].imported)

	testing.expect(t, editor.editor_save(&e, path))
	testing.expect(t, os.exists(OUT + "/scattered/models/bushes.glb"))
	testing.expect(t, os.exists(OUT + "/scattered/models/rock.glb"))
	testing.expect(t, !os.exists(OUT + "/scattered/models/big-rock.glb"), "a model no instance is of was saved")
	testing.expect(t, editor.editor_open(&e, path))
	testing.expect_value(t, len(e.project.instances), len(placed))
	testing.expect(t, drawn(&e) == scattered, "the project opened again draws otherwise")
}
