package data

import "core:fmt"
import "core:reflect"
import "core:strconv"
import "core:strings"

import "dr:sim"

// Builds sim.Defs from the original's resources.
//
// Each generated struct in sim/defs_gen.odin tags its fields with the key the
// original loader reads, so filling one is a reflection walk rather than a
// hand-maintained table that could drift from the layouts.

Defs_Report :: struct {
	units:       int,
	missing:     int, // keys a struct declares that a record did not supply
	malformed:   int, // values that did not parse as the field's type
	first_malformed: string,
	perm_floats: int,
	sprites:     int,
	bad_plates:  int,
	levels:      int,
}

// Level play order: the twelve identifiers G_Level_BuildInfoList compares
// against, stored encrypted (tagged-text transform) at 0x4e7ba9 in the
// executable, 64 bytes apart. Level n is the level whose identifier is the
// n-th name.
LEVEL_ORDER := [12]string {
	"Lucena", "Yippe", "Vista", "Swoop", "Conrad", "Delos",
	"Sparta", "Saratoga", "Hannibal", "Leonidas", "Thebes", "Yamato",
}

// Fills `dst` from `fields` by each field's `dr` tag. Absent keys keep the
// value already in `dst`, so a caller that pre-sets defaults keeps them.
def_fill :: proc(dst: ^$T, fields: []Tag, report: ^Defs_Report, allocator := context.allocator) {
	for f in reflect.struct_fields_zipped(T) {
		key := string(reflect.struct_tag_get(f.tag, "dr"))
		if key == "" {
			continue
		}
		value, found := def_find(fields, key)
		if !found {
			report.missing += 1
			continue
		}
		ptr := rawptr(uintptr(dst) + f.offset)
		if !fill_value(ptr, f.type.id, value, allocator) {
			if report.malformed == 0 {
				report.first_malformed = fmt.aprintf("%s = %q", key, value, allocator = allocator)
			}
			report.malformed += 1
		}
	}
}

@(private = "file")
fill_value :: proc(ptr: rawptr, id: typeid, value: string, allocator := context.allocator) -> bool {
	switch id {
	case i32:
		v, ok := tag_int(value)
		(^i32)(ptr)^ = i32(v)
		return ok
	case f32:
		// FIDELITY NOTE: parsed to f64 and rounded once to f32. The original
		// uses MSL's scanf; the oracle compares RandomFloat bounds bit for bit,
		// so any difference in float parsing shows up there.
		v, ok := tag_float(value)
		(^f32)(ptr)^ = f32(v)
		return ok
	case bool:
		v, ok := tag_bool(value)
		(^bool)(ptr)^ = v
		return ok
	case sim.Res_ID:
		v, ok := tag_fourcc(value)
		(^sim.Res_ID)(ptr)^ = sim.Res_ID(v)
		return ok
	case sim.Color:
		v, ok := tag_rgb(value)
		(^sim.Color)(ptr)^ = sim.Color(v)
		return ok
	case sim.Rect:
		// Text order is left, top, right, bottom: U_Token_GetRect stores its
		// second value in U_Rect.top, the first in .left, the fourth in
		// .bottom and the third in .right.
		r, ok := tag_rect(value)
		(^sim.Rect)(ptr)^ = rect_from(r)
		return ok
	case string:
		(^string)(ptr)^ = strings.clone(value, allocator)
		return true
	}
	return false
}

rect_from :: proc "contextless" (r: Rect) -> sim.Rect {
	return {top = i32(r.top), left = i32(r.left), bottom = i32(r.bottom), right = i32(r.right)}
}

// Converts one parsed unit definition.
unit_from_definition :: proc(d: ^Definition, report: ^Defs_Report, allocator := context.allocator) -> (u: sim.Unit) {
	u.id = sim.Res_ID(d.id)
	def_fill(&u.def, d.header, report, allocator)
	u.states = make([]sim.Unit_State, len(d.states), allocator)
	for &src, i in d.states {
		st := &u.states[i]
		def_fill(&st.def, src.fields, report, allocator)
		// The state scope opens at its name, so the parser keeps it apart
		// rather than in `fields`; it is not missing.
		st.name = strings.clone(src.name, allocator)
		report.missing -= 1
		st.spawn_sets = make([]sim.Spawn_Set_Def, len(src.spawn_sets), allocator)
		for &ss, j in src.spawn_sets {
			def_fill(&st.spawn_sets[j], ss.fields, report, allocator)
		}
		st.rules = make([]sim.Rule, len(src.rules), allocator)
		for r, j in src.rules {
			st.rules[j] = sim.Rule {
				name      = strings.clone(r.name, allocator),
				unit      = sim.Res_ID(r.unit),
				range     = i32(r.range),
				condition = u8(r.condition),
				action    = strings.clone(r.action, allocator),
			}
		}
	}
	return
}

// Loads every unit definition and the permanent tables through the provider,
// so Data/Local overrides apply exactly as in the original.
defs_load :: proc(p: ^Resource_Provider, allocator := context.allocator) -> (defs: sim.Defs, report: Defs_Report) {
	units := make([dynamic]sim.Unit, allocator)
	for e, n in p.entries {
		if e.key.type != fourcc_from("unde") {
			continue
		}
		// Shadowed entries (a PAK copy of a Local file) are not the one the
		// game reads; only take the entry the index resolves to.
		key := e.key
		if i, ok := p.index[key]; !ok || i != n {
			continue
		}
		id := key.id
		body, owned, err := resource_get(p, "unde", fourcc_string(&id), allocator)
		if err != .None {
			continue
		}
		d, derr := definition_parse(key.id, body, context.temp_allocator)
		if owned {
			delete(body, allocator)
		}
		if derr != .None {
			continue
		}
		append(&units, unit_from_definition(&d, &report, allocator))
	}
	defs.units = units[:]
	report.units = len(units)

	// Sprite groups: every upper-case im08 id is an alpha plate.
	sprites := make([dynamic]sim.Sprite, allocator)
	for e, n in p.entries {
		key := e.key
		if key.type != fourcc_from("im08") {
			continue
		}
		if i, ok := p.index[key]; !ok || i != n {
			continue
		}
		upper := true
		for c in key.id {
			if c >= 'a' && c <= 'z' {
				upper = false
			}
		}
		if !upper {
			continue
		}
		body, owned, err := resource_get(p, "im08", fourcc_string(&key.id), context.temp_allocator)
		if err != .None {
			continue
		}
		_ = owned
		g, gerr := gif_decode(body, context.temp_allocator)
		if gerr != .None {
			report.bad_plates += 1
			continue
		}
		frames, perr := plate_frames(g.pixels, g.width, g.height, context.temp_allocator)
		if perr != .None {
			report.bad_plates += 1
			continue
		}
		spr := sim.Sprite{id = sim.res_id_lower(sim.Res_ID(key.id))}
		spr.frames = make([]sim.Sprite_Frame, len(frames), allocator)
		for f, i in frames {
			spr.frames[i] = {i32(f.width), i32(f.height)}
		}
		append(&sprites, spr)
	}
	defs.sprites = sprites[:]
	report.sprites = len(sprites)

	// Player definitions: flat plde records.
	players := make([dynamic]sim.Player_Entry, allocator)
	for e, n in p.entries {
		key := e.key
		if key.type != fourcc_from("plde") {
			continue
		}
		if i, ok := p.index[key]; !ok || i != n {
			continue
		}
		body, owned, err := resource_get(p, "plde", fourcc_string(&key.id), context.temp_allocator)
		if err != .None {
			continue
		}
		_ = owned
		d, derr := definition_parse(key.id, body, context.temp_allocator)
		if derr != .None {
			continue
		}
		pe := sim.Player_Entry{id = sim.Res_ID(key.id)}
		def_fill(&pe.def, d.header, &report, allocator)
		append(&players, pe)
	}
	defs.players = players[:]

	// Levels, in play order.
	levels := make([dynamic]sim.Level_Def, allocator)
	for name, i in LEVEL_ORDER {
		for e, n in p.entries {
			key := e.key
			if key.type != fourcc_from("leve") {
				continue
			}
			if j, ok := p.index[key]; !ok || j != n {
				continue
			}
			body, _, err := resource_get(p, "leve", fourcc_string(&key.id), context.temp_allocator)
			if err != .None {
				continue
			}
			lv, lerr := level_parse(body, context.temp_allocator)
			if lerr != .None || lv.identifier != name {
				continue
			}
			l := sim.Level_Def {
				id         = sim.Res_ID(key.id),
				identifier = strings.clone(lv.identifier, allocator),
				number     = i32(i + 1),
				background = rect_from(lv.background),
				placements = make([]sim.Placement_Def, len(lv.placements), allocator),
			}
			for pl, k in lv.placements {
				l.placements[k] = {
					unit            = sim.Res_ID(pl.unit),
					x               = i32(pl.x),
					y               = i32(pl.y),
					heading         = i32(pl.heading_degrees),
					stationary      = pl.is_stationary,
					terrain_effects = pl.terrain_effects,
				}
			}
			append(&levels, l)
			break
		}
	}
	defs.levels = levels[:]
	report.levels = len(levels)

	// flli "gafl": 220 floats read positionally (FUN_004383b0).
	if body, owned, err := resource_get(p, "flli", "gafl", context.temp_allocator); err == .None {
		text := tagged_decode(body, context.temp_allocator)
		tags := tagged_parse(text, context.temp_allocator)
		for t, i in tags {
			if i >= sim.PERM_FLOATS {
				break
			}
			v, _ := strconv.parse_f64(strings.trim_space(t.value))
			defs.perm_floats[i] = f32(v)
			report.perm_floats += 1
		}
		_ = owned
	}
	// idli "gaob": 40 object ids.
	if body, _, err := resource_get(p, "idli", "gaob", context.temp_allocator); err == .None {
		text := tagged_decode(body, context.temp_allocator)
		tags := tagged_parse(text, context.temp_allocator)
		for t, i in tags {
			if i >= sim.PERM_OBJECTS {
				break
			}
			v, _ := tag_fourcc(t.value)
			defs.perm_objects[i] = sim.Res_ID(v)
		}
	}
	return
}
