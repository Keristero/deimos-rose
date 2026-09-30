package editor

// Placing units: the level record's placements, put down, picked up,
// moved, turned and taken away on the map. Every change goes through
// placements_changing and settles as one edit (placements_settle), as the
// sliders' do, so a drag undoes as one.

import "core:c"
import "core:math"
import "core:slice"

import "dr:data"
import "dr:sim"

// The level record's layers, as the originals write them.
LAYER_GROUND :: "grnd"
LAYER_AIR :: "air "

// Rows above the view's top at which a placement spawns: the background
// spawns row view_top - 64 (bgnd_process, eg_spawn_map_row).
SPAWN_AHEAD :: 64
// The least a placement is picked by, around its point, in map pixels.
PICK_MIN :: 6
// Q and E turn the selected unit by this; with Shift, by a degree.
TURN_STEP :: 15

Layer_Filter :: enum c.int {
	Both,
	Ground,
	Air,
}

Placing :: struct {
	selected:            int, // in project.placements, or -1
	hovered:             int,
	palette_unit:        int, // in units.defs.units, or -1
	palette_scroll:      c.int,
	layers:              c.int, // Layer_Filter: the palette and the map
	show_units:          bool,
	dragging_unit:       bool,
	drag_offset:         [2]f32,
	// The units as last recorded, while a change is under way.
	placements_before:   [dynamic]data.Json_Placement,
	placements_changing: bool,
}

placing_init :: proc(pl: ^Placing) {
	pl.selected, pl.hovered, pl.palette_unit = -1, -1, -1
	pl.show_units = true
}

placing_destroy :: proc(pl: ^Placing) {
	delete(pl.placements_before)
	pl.placements_before = nil
}

// Whether a placement is on the ground: its unit's say, as the spawn's
// (spawn.odin), else its layer's for a unit this build does not have.
placement_ground :: proc(units: ^Catalogue, pl: data.Json_Placement) -> bool {
	if u := catalogue_unit(units, pl.unit); u != nil {
		return u.is_ground_based
	}
	return pl.layer == LAYER_GROUND
}

// The map pixel a placement's unit is centred on. A ground placement's x is
// the map's column; an air placement's the play field's, which starts 32
// columns into the map.
placement_point :: proc(units: ^Catalogue, pl: data.Json_Placement) -> [2]f32 {
	x := f32(pl.x)
	if !placement_ground(units, pl) {
		x += sim.GROUND_PLACEMENT_SHIFT
	}
	return {x, f32(pl.y)}
}

// The record's x and y for a unit centred on map pixel `at`.
placement_at :: proc(units: ^Catalogue, pl: ^data.Json_Placement, at: [2]f32) {
	x := int(math.round(at.x))
	if !placement_ground(units, pl^) {
		x -= sim.GROUND_PLACEMENT_SHIFT
	}
	pl.x, pl.y = x, int(math.round(at.y))
}

// Whether the level's heading counts for a placement: the game takes it
// only for a unit whose editor sets it (spawn.odin, initialHeadingSetInEditor),
// and gives the others their own.
placement_turns :: proc(e: ^Editor, pl: data.Json_Placement) -> bool {
	u := catalogue_unit(&e.units, pl.unit)
	return u != nil && u.initial_heading_set_in_editor
}

// Whether the layer filter shows a unit on the ground, or in the air.
layer_shown :: proc(e: ^Editor, ground: bool) -> bool {
	switch Layer_Filter(e.layers) {
	case .Ground:
		return ground
	case .Air:
		return !ground
	case .Both:
	}
	return true
}

placement_shown :: proc(e: ^Editor, pl: data.Json_Placement) -> bool {
	return layer_shown(e, placement_ground(&e.units, pl))
}

// The half-size a placement is picked and outlined by.
placement_extent :: proc(e: ^Editor, pl: data.Json_Placement) -> [2]f32 {
	half := [2]f32{PICK_MIN, PICK_MIN}
	if u := catalogue_unit(&e.units, pl.unit); u != nil {
		sprite, frame := unit_look(u, pl.heading_degrees)
		if size, ok := catalogue_frame_size(&e.units, sprite, frame); ok {
			half = {max(size.x / 2, PICK_MIN), max(size.y / 2, PICK_MIN)}
		}
	}
	return half
}

// The placement under map pixel `at`, or -1: the one drawn on top, air
// over ground and later over earlier.
placement_pick :: proc(e: ^Editor, at: [2]f32) -> int {
	for air in ([2]bool{true, false}) {
		#reverse for pl, i in e.project.placements {
			if placement_ground(&e.units, pl) == air || !placement_shown(e, pl) {
				continue
			}
			d := at - placement_point(&e.units, pl)
			half := placement_extent(e, pl)
			if abs(d.x) <= half.x && abs(d.y) <= half.y {
				return i
			}
		}
	}
	return -1
}

// Before any change to the units: keeps them as they are, once.
placements_changing :: proc(e: ^Editor) {
	if e.placements_changing {
		return
	}
	clear(&e.placements_before)
	append(&e.placements_before, ..e.project.placements[:])
	e.placements_changing = true
}

// Records the change once nothing is being dragged, if the units differ.
placements_settle :: proc(e: ^Editor, dragging: bool) {
	if !e.placements_changing || dragging {
		return
	}
	e.placements_changing = false
	if slice.equal(e.placements_before[:], e.project.placements[:]) {
		return
	}
	history_placements(&e.history, e.placements_before[:])
	e.dirty = true
}

// Puts down a unit of defs.units[unit] centred on `at`, facing up, and
// selects it.
editor_place :: proc(e: ^Editor, unit: int, at: [2]f32) -> int {
	u := &e.units.defs.units[unit]
	placements_changing(e)
	// The unit's own id, which lives as long as the catalogue.
	pl := data.Json_Placement {
		unit  = string(u.id[:]),
		layer = u.is_ground_based ? LAYER_GROUND : LAYER_AIR,
	}
	placement_at(&e.units, &pl, at)
	append(&e.project.placements, pl)
	e.selected = len(e.project.placements) - 1
	return e.selected
}

editor_placement_move :: proc(e: ^Editor, i: int, at: [2]f32) {
	placements_changing(e)
	placement_at(&e.units, &e.project.placements[i], at)
}

// Turns a placement by `degrees`, kept in 0-359.
editor_placement_turn :: proc(e: ^Editor, i: int, degrees: int) {
	placements_changing(e)
	h := &e.project.placements[i].heading_degrees
	h^ = ((h^ + degrees) % 360 + 360) % 360
}

editor_placement_delete :: proc(e: ^Editor, i: int) {
	placements_changing(e)
	ordered_remove(&e.project.placements, i)
	e.selected, e.hovered = -1, -1
}
