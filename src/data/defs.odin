package data

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
	perm_floats: int,
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
		r, ok := tag_rect(value)
		(^sim.Rect)(ptr)^ = sim.Rect{i32(r.left), i32(r.top), i32(r.right), i32(r.bottom)}
		return ok
	case string:
		(^string)(ptr)^ = strings.clone(value, allocator)
		return true
	}
	return false
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
