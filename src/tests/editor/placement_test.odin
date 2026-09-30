package editor_tests

// Placing units (Stage 8 of notes/level-editor-plan.md), on fixture units:
// none of it needs the original data. Drawing one is in editor_draws.

import "core:c"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import rl "vendor:raylib"

import "dr:data"
import "dr:editor"
import "dr:sim"
import "dr:terrain"

// The fixture's one plate: an 8 x 6 frame, and a 4 x 4 one.
@(private = "file")
FIXTURE_FRAMES := [2]data.Json_Frame{{0, 0, 8, 6}, {8, 0, 4, 4}}

// Four units: a ground and an air one in the palette, one that turns with
// its heading, and one the palette leaves out (no preview face).
@(private = "file")
fixture_units :: proc(allocator := context.allocator) -> []sim.Unit {
	states := make([]sim.Unit_State, 1, allocator)
	states[0].sprite_face = sim.res_id("tfix")
	states[0].num_directions = 8
	states[0].frames_per_direction = 1
	states[0].sprite_frame_min = 1
	units := make([]sim.Unit, 4, allocator)
	set :: proc(u: ^sim.Unit, id, name: string, ground: bool, states: []sim.Unit_State) {
		u.id = sim.res_id(id)
		u.name = name
		u.is_ground_based = ground
		u.editor_preview_sprite_face = sim.res_id("tfix")
		u.states = states
	}
	set(&units[0], "tgnd", "Tank", true, states)
	set(&units[1], "tair", "Flyer", false, states)
	set(&units[2], "ttrn", "Turret", true, states)
	units[2].initial_heading_set_in_editor = true
	set(&units[3], "thid", "Hidden", true, states)
	units[3].editor_preview_sprite_face = sim.NONE
	return units
}

// An editor on a flat project, with the fixture's units and no window.
@(private = "file")
fixture_editor :: proc(e: ^editor.Editor) {
	editor.editor_init(e)
	e.project = terrain.project_make(480, 400, context.temp_allocator)
	e.units.defs.units = fixture_units(context.temp_allocator)
	editor.catalogue_index(&e.units)
	e.units.plates[sim.res_id("tfix")] = {frames = FIXTURE_FRAMES[:], loaded = true}
}

@(private = "file")
fixture_destroy :: proc(e: ^editor.Editor) {
	// The project and the units are the test's; editor_destroy frees the rest.
	e.units.defs = {}
	e.project = {}
	editor.editor_destroy(e)
}

@(private = "file")
unit_index :: proc(e: ^editor.Editor, id: string) -> int {
	for &u, i in e.units.defs.units {
		if string(u.id[:]) == id {
			return i
		}
	}
	return -1
}

// The palette is the units with a preview face, by name; the layer filter
// keeps the ground's or the air's.
@(test)
palette_is_the_previewed_units :: proc(t: ^testing.T) {
	e: editor.Editor
	fixture_editor(&e)
	defer fixture_destroy(&e)
	names :: proc(e: ^editor.Editor, list: []int) -> (out: [dynamic]string) {
		out = make([dynamic]string, context.temp_allocator)
		for i in list {
			append(&out, e.units.defs.units[i].name)
		}
		return
	}
	testing.expect(t, slice.equal(names(&e, e.units.palette[:])[:], []string{"Flyer", "Tank", "Turret"}))
	e.layers = c.int(editor.Layer_Filter.Ground)
	testing.expect(t, slice.equal(names(&e, editor.palette_shown(&e))[:], []string{"Tank", "Turret"}))
	e.layers = c.int(editor.Layer_Filter.Air)
	testing.expect(t, slice.equal(names(&e, editor.palette_shown(&e))[:], []string{"Flyer"}))
}

// A ground placement's x is the map's column, an air one's the play
// field's, 32 to the right on the map; a unit this build lacks goes by its
// layer.
@(test)
placements_map_both_layers :: proc(t: ^testing.T) {
	e: editor.Editor
	fixture_editor(&e)
	defer fixture_destroy(&e)
	cat := &e.units
	testing.expect_value(t, editor.placement_point(cat, {unit = "tgnd", layer = "grnd", x = 100, y = 50}), [2]f32{100, 50})
	testing.expect_value(t, editor.placement_point(cat, {unit = "tair", layer = "air ", x = 100, y = 50}), [2]f32{132, 50})
	testing.expect_value(t, editor.placement_point(cat, {unit = "zzzz", layer = "air ", x = 100, y = 50}), [2]f32{132, 50})
	testing.expect_value(t, editor.placement_point(cat, {unit = "zzzz", layer = "grnd", x = 100, y = 50}), [2]f32{100, 50})
	for id in ([]string{"tgnd", "tair"}) {
		pl := data.Json_Placement{unit = id}
		editor.placement_at(cat, &pl, {200.4, 77.6})
		testing.expect_value(t, editor.placement_point(cat, pl), [2]f32{200, 78})
	}
	ground := data.Json_Placement{unit = "tgnd"}
	editor.placement_at(cat, &ground, {200, 78})
	testing.expect_value(t, ground.x, 200)
	air := data.Json_Placement{unit = "tair"}
	editor.placement_at(cat, &air, {200, 78})
	testing.expect_value(t, air.x, 200 - sim.GROUND_PLACEMENT_SHIFT)
}

// The look: the first state's sprite at its least frame, or turned with the
// heading when the editor sets it; the preview when asked for, or when the
// first state draws nothing.
@(test)
unit_look_reads_the_flags :: proc(t: ^testing.T) {
	units := fixture_units(context.temp_allocator)
	fix := sim.res_id("tfix")
	s, f := editor.unit_look(&units[0], 90)
	testing.expect(t, s == fix && f == 1, "a unit that does not turn shows its least frame")
	s, f = editor.unit_look(&units[2], 90)
	testing.expect_value(t, f, 2) // eight directions, 45 degrees each
	testing.expect_value(t, int(sim.state_frame_for_angle(&units[2].states[0], 90)), 2)
	s, f = editor.unit_look(&units[2], 350)
	testing.expect_value(t, f, 0) // nearest is 360, which wraps
	units[1].use_preview_appearance_in_placement_editor = true
	units[1].editor_preview_sprite_face = sim.res_id("tprv")
	units[1].editor_preview_sprite_frame = 5
	s, f = editor.unit_look(&units[1], 0)
	testing.expect(t, s == sim.res_id("tprv") && f == 5, "the preview when asked for")
	marker := sim.Unit{states = make([]sim.Unit_State, 1, context.temp_allocator)}
	marker.states[0].sprite_face = sim.NONE
	marker.editor_preview_sprite_face = sim.res_id("edpr")
	marker.editor_preview_sprite_frame = 25
	s, f = editor.unit_look(&marker, 0)
	testing.expect(t, s == sim.res_id("edpr") && f == 25, "the preview when the state draws nothing")
}

// Place, drag, turn and delete each undo as one change, to the list
// before, and redo to the list after.
@(test)
placing_undoes_as_one :: proc(t: ^testing.T) {
	e: editor.Editor
	fixture_editor(&e)
	defer fixture_destroy(&e)
	list :: proc(e: ^editor.Editor) -> []data.Json_Placement {
		return slice.clone(e.project.placements[:], context.temp_allocator)
	}
	step :: proc(t: ^testing.T, e: ^editor.Editor, before, after: []data.Json_Placement) {
		testing.expect(t, editor.editor_undo(e))
		testing.expect(t, slice.equal(e.project.placements[:], before), "the undo is not the list before")
		testing.expect(t, editor.editor_redo(e))
		testing.expect(t, slice.equal(e.project.placements[:], after), "the redo is not the list after")
	}

	empty := list(&e)
	i := editor.editor_place(&e, unit_index(&e, "tgnd"), {100, 200})
	editor.placements_settle(&e, false)
	placed := list(&e)
	testing.expect_value(t, len(placed), 1)
	testing.expect(t, placed[0].unit == "tgnd" && placed[0].layer == editor.LAYER_GROUND)
	testing.expect_value(t, e.selected, i)
	testing.expect(t, e.dirty)
	step(t, &e, empty, placed)

	air := editor.editor_place(&e, unit_index(&e, "tair"), {300, 150})
	editor.placements_settle(&e, false)
	testing.expect(t, e.project.placements[air].layer == editor.LAYER_AIR && e.project.placements[air].x == 300 - sim.GROUND_PLACEMENT_SHIFT)
	two := list(&e)

	// A drag of many moves is one change.
	for k in 1 ..= 10 {
		editor.editor_placement_move(&e, i, {100 + f32(k) * 5, 200 - f32(k)})
		editor.placements_settle(&e, true)
	}
	editor.placements_settle(&e, false)
	moved := list(&e)
	testing.expect_value(t, moved[i].x, 150)
	testing.expect_value(t, moved[i].y, 190)
	step(t, &e, two, moved)

	editor.editor_placement_turn(&e, i, -editor.TURN_STEP)
	editor.placements_settle(&e, false)
	turned := list(&e)
	testing.expect_value(t, turned[i].heading_degrees, 360 - editor.TURN_STEP)
	step(t, &e, moved, turned)

	editor.editor_placement_delete(&e, i)
	editor.placements_settle(&e, false)
	deleted := list(&e)
	testing.expect_value(t, len(deleted), 1)
	testing.expect(t, deleted[0].unit == "tair")
	step(t, &e, turned, deleted)

	// A change that ends as it began records nothing.
	done := len(e.history.done)
	editor.editor_placement_turn(&e, 0, 10)
	editor.editor_placement_turn(&e, 0, -10)
	editor.placements_settle(&e, false)
	testing.expect_value(t, len(e.history.done), done)
}

// When the vents change, the level has the one detector for their number
// on the northmost vent, as the originals have; a change of other units
// leaves the detectors as they are; and the detector undoes with the vents.
@(test)
vents_keep_their_detector :: proc(t: ^testing.T) {
	e: editor.Editor
	fixture_editor(&e)
	defer fixture_destroy(&e)
	vent :: proc(e: ^editor.Editor, x, y: int) {
		editor.placements_changing(e)
		append(&e.project.placements, data.Json_Placement{unit = editor.VENT, layer = editor.LAYER_GROUND, x = x, y = y})
		editor.placements_settle(e, false)
	}
	detectors :: proc(e: ^editor.Editor) -> (found: [dynamic]data.Json_Placement) {
		found.allocator = context.temp_allocator
		for pl in e.project.placements {
			if pl.unit == "gebd" || pl.unit == "05gb" || pl.unit == "gbd2" {
				append(&found, pl)
			}
		}
		return
	}
	vent(&e, 100, 300)
	testing.expect_value(t, len(detectors(&e)), 0)
	vent(&e, 200, 120)
	if d := detectors(&e); testing.expect_value(t, len(d), 1) {
		testing.expect(t, d[0].unit == "gebd" && d[0].x == 200 && d[0].y == 120, "not gebd on the northmost vent")
	}
	vent(&e, 50, 250)
	vent(&e, 60, 90)
	if d := detectors(&e); testing.expect_value(t, len(d), 1) {
		testing.expect(t, d[0].unit == "gbd2" && d[0].x == 60 && d[0].y == 90, "not gbd2 on the northmost vent")
	}
	vent(&e, 70, 400)
	testing.expect_value(t, len(detectors(&e)), 0)

	testing.expect(t, editor.editor_undo(&e))
	if d := detectors(&e); testing.expect_value(t, len(d), 1) {
		testing.expect(t, d[0].unit == "gbd2", "the undo did not bring back the detector")
	}
	// A detector moved by hand stays where it is while the vents do not change.
	for &pl in e.project.placements {
		if pl.unit == "gbd2" {
			editor.placements_changing(&e)
			pl.x = 10
		}
	}
	editor.editor_place(&e, unit_index(&e, "tgnd"), {300, 300})
	editor.placements_settle(&e, false)
	testing.expect_value(t, detectors(&e)[0].x, 10)
	n, north := editor.vents_count(e.project.placements[:])
	testing.expect_value(t, n, 4)
	testing.expect_value(t, e.project.placements[north].y, 90)
}

// The history keeps count of the lists it holds as they swap.
@(test)
placement_history_counts_its_bytes :: proc(t: ^testing.T) {
	p := terrain.project_make(8, 8, context.temp_allocator)
	h: editor.History
	defer editor.history_destroy(&h)
	editor.history_placements(&h, p.placements[:])
	append(&p.placements, data.Json_Placement{unit = "tgnd"}, data.Json_Placement{unit = "tair"})
	testing.expect_value(t, h.bytes, 0)
	c, ok := editor.history_undo(&h, &p)
	testing.expect(t, ok && c.placements && !c.map_ && !c.settings)
	testing.expect_value(t, len(p.placements), 0)
	testing.expect_value(t, h.bytes, 2 * size_of(data.Json_Placement))
	editor.history_redo(&h, &p)
	testing.expect_value(t, len(p.placements), 2)
	testing.expect_value(t, h.bytes, 0)
}

// The topmost placement is picked: air over ground, later over earlier, by
// its frame's size, and at least PICK_MIN about its point; the filter
// leaves out what it hides.
@(test)
pick_takes_the_one_on_top :: proc(t: ^testing.T) {
	e: editor.Editor
	fixture_editor(&e)
	defer fixture_destroy(&e)
	air := editor.editor_place(&e, unit_index(&e, "tair"), {100, 100})
	ground := editor.editor_place(&e, unit_index(&e, "tgnd"), {100, 100})
	later := editor.editor_place(&e, unit_index(&e, "tgnd"), {300, 100})
	earlier_under := editor.editor_place(&e, unit_index(&e, "tgnd"), {300, 100})
	testing.expect_value(t, editor.placement_pick(&e, {100, 100}), air)
	testing.expect_value(t, editor.placement_pick(&e, {300, 100}), earlier_under)
	_ = later
	e.layers = c.int(editor.Layer_Filter.Ground)
	testing.expect_value(t, editor.placement_pick(&e, {100, 100}), ground)
	e.layers = c.int(editor.Layer_Filter.Both)
	// The ground fixture shows frame 1, 4 x 4: picked out to PICK_MIN.
	testing.expect_value(t, editor.placement_pick(&e, {300 + editor.PICK_MIN, 100}), earlier_under)
	testing.expect_value(t, editor.placement_pick(&e, {300 + editor.PICK_MIN + 1, 100}), -1)
}

// The placements save into the level record and open as they were.
@(test)
placements_save_and_reopen :: proc(t: ^testing.T) {
	p := terrain.project_make(40, 30, context.temp_allocator)
	append(&p.placements, data.Json_Placement{unit = "plla", layer = "grnd", x = 12, y = 20, heading_degrees = 330}, data.Json_Placement{unit = "bu01", layer = "air ", x = 3, y = 7, is_stationary = true, terrain_effects = true})
	path :: OUT + "/placements.drproj.json"
	os.make_directory_all(OUT)
	testing.expect(t, terrain.project_save(&p, path))
	q, ok := terrain.project_load(path, context.temp_allocator)
	if !testing.expect(t, ok) {
		return
	}
	testing.expect(t, slice.equal(q.placements[:], p.placements[:]), "the placements came back otherwise")
	testing.expect(t, q.level.placements == nil, "the level record keeps a second copy")
}

// A unit placed in view is drawn there, its frame centred on its point,
// over the base the maps bake under it, which moves with it.
units_draw_on_the_map :: proc(t: ^testing.T) {
	L :: 1000
	p := hills(120, L, context.temp_allocator)
	path :: OUT + "/units.drproj.json"
	testing.expect(t, terrain.project_save(&p, path))
	e: editor.Editor
	editor.editor_init(&e)
	defer editor.editor_destroy(&e)
	if !testing.expect(t, editor.editor_open(&e, path)) {
		return
	}
	e.units.defs.units = fixture_units(context.temp_allocator)
	defer e.units.defs = {}
	editor.catalogue_index(&e.units)
	red := rl.GenImageColor(12, 6, {255, 0, 0, 255})
	defer rl.UnloadImage(red)
	e.units.plates[sim.res_id("tfix")] = {frames = FIXTURE_FRAMES[:], texture = rl.LoadTextureFromImage(red), loaded = true}
	blue := rl.GenImageColor(10, 10, {0, 0, 255, 255})
	defer rl.UnloadImage(blue)
	e.units.bases[strings.clone("tgnd")] = {texture = rl.LoadTextureFromImage(blue), loaded = true}
	e.tab = c.int(editor.Tab.Units)

	W, H :: 800, 600
	l := editor.layout(W, H)
	// Half a view up from the bottom of the level, where the view opens.
	at := [2]f32{60, L - l.view.height / 2}
	editor.editor_place(&e, unit_index(&e, "tgnd"), at)
	editor.placements_settle(&e, false)
	e.selected = -1
	img := editor.editor_shot(&e, W, H)
	defer rl.UnloadImage(img)
	rl.ExportImage(img, OUT + "/units.png")
	px := ([^]u8)(img.data)[:W * H * 3]
	x0 := int(l.view.x) + (int(l.view.width) - 120) / 2
	cx, cy := x0 + int(at.x), int(at.y) - (L - int(l.view.height))
	// Frame 1 is 4 x 4, drawn from 2 left and 2 up of the point.
	red_at :: proc(px: []u8, x, y: int) -> bool {
		c := px[(y * W + x) * 3:][:3]
		return c[0] == 255 && c[1] == 0 && c[2] == 0
	}
	testing.expect(t, red_at(px, cx - 2, cy - 2) && red_at(px, cx + 1, cy + 1), "the unit's frame is not at its point")
	testing.expect(t, !red_at(px, cx + 3, cy) && !red_at(px, cx - 3, cy), "the unit's frame is wider than its frame")
	// The base is 10 x 10, from 5 left and 5 up of the point, under the frame.
	blue_at :: proc(px: []u8, x, y: int) -> bool {
		c := px[(y * W + x) * 3:][:3]
		return c[0] == 0 && c[1] == 0 && c[2] == 255
	}
	testing.expect(t, blue_at(px, cx - 5, cy - 5) && blue_at(px, cx + 4, cy + 4), "the unit's base is not under its point")
	testing.expect(t, !blue_at(px, cx - 6, cy) && !blue_at(px, cx + 5, cy), "the unit's base is wider than its image")

	e.project.placements[0].x += 20
	moved := editor.editor_shot(&e, W, H)
	defer rl.UnloadImage(moved)
	px = ([^]u8)(moved.data)[:W * H * 3]
	testing.expect(t, blue_at(px, cx + 15, cy - 5) && !blue_at(px, cx - 5, cy - 5), "the base did not move with its unit")
}
