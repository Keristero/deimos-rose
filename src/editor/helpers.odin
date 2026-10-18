package editor

// The placing helpers (Stage 8): the obstacle and the vent, picked with a
// button, and the vents' bonus detector kept as the originals keep it.
//
// A destroyed vent (geys) leaves a flag (its destructSpawn_ID, gedf). A
// detector's first state waits until exactly its number of flags have
// appeared, anywhere (its rule's range, "Number of This Type of Entity
// Active"; rules.odin, count_appeared), then pays out: gebd at 2, 05gb at
// 3 and gbd2 at 4. The three levels with vents each have one detector,
// counting all of the level's vents and put on the northmost, the last
// the player reaches: le05's gbd2 on its vent at (122, 165), le07's gebd
// 2 px from its vent at (264, 443), le11's 05gb 1 px from its vent at
// (158, 1410). So when a level's vents change, the detector is put back
// on that rule: one, for their number, on the northmost vent; none for
// one vent or more than four, which no detector counts.

import "core:c"
import "core:fmt"
import "core:slice"

import rl "vendor:raylib"

import "dr:data"

// The invisible units that give scenery its collision (33 in the
// originals), and the vents.
OBSTACLE :: "grob"
VENT :: "geys"

// The detector for each number of vents, by the rules' ranges.
@(private = "file")
VENT_DETECTORS := [5]string{2 = "gebd", 3 = "05gb", 4 = "gbd2"}

// The detector for `vents` vents, or "".
vent_detector :: proc(vents: int) -> string {
	return vents >= 0 && vents < len(VENT_DETECTORS) ? VENT_DETECTORS[vents] : ""
}

@(private = "file")
is_detector :: proc(unit: string) -> bool {
	for d in VENT_DETECTORS {
		if d != "" && unit == d {
			return true
		}
	}
	return false
}

// The level's vents, and the northmost's index, or -1.
vents_count :: proc(placements: []data.Json_Placement) -> (n: int, north: int) {
	north = -1
	for pl, i in placements {
		if pl.unit == VENT {
			n += 1
			if north < 0 || pl.y < placements[north].y {
				north = i
			}
		}
	}
	return
}

// After a change to the units, if it changed the vents: the detectors
// taken away, and the one for their number put on the northmost. A level
// whose vents are not touched keeps its detectors as they are. Part of the
// same edit, so it undoes with the change that caused it.
vents_settle :: proc(e: ^Editor) {
	vents :: proc(placements: []data.Json_Placement) -> []data.Json_Placement {
		out := make([dynamic]data.Json_Placement, context.temp_allocator)
		for pl in placements {
			if pl.unit == VENT {
				append(&out, pl)
			}
		}
		return out[:]
	}
	if slice.equal(vents(e.placements_before[:]), vents(e.project.placements[:])) {
		return
	}
	list := &e.project.placements
	for i := len(list) - 1; i >= 0; i -= 1 {
		if is_detector(list[i].unit) {
			ordered_remove(list, i)
			if e.selected == i {
				e.selected = -1
			} else if e.selected > i {
				e.selected -= 1
			}
		}
	}
	n, north := vents_count(list[:])
	if d := vent_detector(n); d != "" {
		// A constant's string, which outlives the project's list.
		append(list, data.Json_Placement{unit = d, layer = LAYER_GROUND, x = list[north].x, y = list[north].y})
	}
	e.hovered = -1
}

// The helpers' row in the Units tab: a button for each, which picks it in
// the palette, and what the vents' detector does.
helpers_panel :: proc(e: ^Editor, x: f32, y: ^f32, w: f32) {
	bw := (w - 4) / 2
	pick :: proc(e: ^Editor, id: string) {
		if i := palette_find(e, id); i >= 0 {
			e.palette_unit = i
			e.layers = c.int(Layer_Filter.Both)
		}
	}
	if rl.GuiButton({x, y^, bw, 20}, "Obstacle") {
		pick(e, OBSTACLE)
	}
	if rl.GuiButton({x + bw + 4, y^, bw, 20}, "Vent") {
		pick(e, VENT)
	}
	y^ += ROW
	n, _ := vents_count(e.project.placements[:])
	switch d := vent_detector(n); {
	case n == 0:
		return
	case d != "":
		rl.GuiLabel({x, y^, w, 20}, fmt.ctprintf("%d vents: %s pays out when all are destroyed", n, d))
	case:
		rl.GuiLabel({x, y^, w, 20}, fmt.ctprintf("%d vents: no detector counts %d (2 to 4)", n, n))
	}
	y^ += 20
}
