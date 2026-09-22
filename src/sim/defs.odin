package sim

// Definitions: the read-only game data the simulation runs on. Loaded once by
// data/ from our JSON records and never mutated, so a State refers to them by
// pointer and a rollback snapshot does not copy them.
//
// The per-record structs (Unit_Def, State_Def, ...) are generated from the
// original's own loaders -- see defs_gen.odin.

// A four-byte resource id ("le07", "air "). The original compares these as
// little-endian u32s (0x656e6f6e is "none"), which is the same as comparing
// the bytes. Whitespace is significant.
Res_ID :: distinct [4]u8

NONE :: Res_ID{'n', 'o', 'n', 'e'}

res_id :: proc "contextless" (s: string) -> (id: Res_ID) {
	for i in 0 ..< 4 {
		id[i] = i < len(s) ? s[i] : ' '
	}
	return
}

// Ordered as the original's U_Rect: left, top, right, bottom.
Rect :: struct {
	left, top, right, bottom: i32,
}

Color :: [3]u8

// A rule as the state loader reads it. Its fields go through locals in the
// original, so they are not in the generated layouts; see data/definition.odin.
Rule :: struct {
	name:      string,
	unit:      Res_ID,
	range:     i32,
	condition: u8, // data.Rule_Condition
	action:    string,
}

Unit_State :: struct {
	using def:  State_Def,
	spawn_sets: []Spawn_Set_Def,
	rules:      []Rule,
}

Unit :: struct {
	id:        Res_ID,
	using def: Unit_Def,
	states:    []Unit_State,
}

// Sizes of the original's permanent tables (G_Res_LoadPermData).
PERM_FLOATS :: 220 // flli "gafl"
PERM_OBJECTS :: 40 // idli "gaob"

// One frame of a sprite group: the trimmed box from its alpha plate
// (data/sprite_plate.odin). Only the size matters to the simulation.
Sprite_Frame :: struct {
	width, height: i32,
}

// Sprite groups are keyed by the lower-cased id: U_Sprite_Load cuts the
// upper-cased alpha plate, and unit data names sprites in lower case.
Sprite :: struct {
	id:     Res_ID,
	frames: []Sprite_Frame,
}

Defs :: struct {
	units:        []Unit,
	sprites:      []Sprite,
	perm_floats:  [PERM_FLOATS]f32,
	perm_objects: [PERM_OBJECTS]Res_ID,
}

unit_find :: proc "contextless" (d: ^Defs, id: Res_ID) -> ^Unit {
	for &u in d.units {
		if u.id == id {
			return &u
		}
	}
	return nil
}

sprite_find :: proc "contextless" (d: ^Defs, id: Res_ID) -> ^Sprite {
	key := res_id_lower(id)
	for &s in d.sprites {
		if s.id == key {
			return &s
		}
	}
	return nil
}

res_id_lower :: proc "contextless" (id: Res_ID) -> (out: Res_ID) {
	for c, i in id {
		out[i] = c >= 'A' && c <= 'Z' ? c + 32 : c
	}
	return
}

// State lookup by name, as G_Entity::ChangeState does it: a linear scan in
// which the *last* matching state wins. No shipped unit has duplicate state
// names (checked across all 386), so this only matters for modded data.
state_find :: proc "contextless" (u: ^Unit, name: string) -> (index: int, ok: bool) {
	index = -1
	for s, i in u.states {
		if s.name == name {
			index = i
		}
	}
	return index, index >= 0
}
