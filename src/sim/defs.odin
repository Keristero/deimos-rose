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

// The original's U_Rect, in its field order: top, left, bottom, right
// (G_GameObject::GetBounds writes +0 top, +4 left, +8 bottom, +c right).
Rect :: struct {
	top, left, bottom, right: i32,
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

// A level placement (G_Level object record).
Placement_Def :: struct {
	unit:            Res_ID,
	x, y:            i32,
	heading:         i32,
	stationary:      bool,
	terrain_effects: bool,
}

Level_Def :: struct {
	id:         Res_ID,
	identifier: string,
	// 1-based play order. G_Level_BuildInfoList numbers levels by matching
	// each level's identifier against twelve encrypted names built into the
	// executable (0x4e7ba9): Lucena (le07) is 1, Yippe (le06) 2, Vista (le02)
	// 3, Swoop (le08) 4, ... The four demos play levels 1-4 in order.
	number:     i32,
	background: Rect,
	placements: []Placement_Def,
	// The media mask (im16 TGA named by the level's mediaMask_ID): raw 16-bit
	// pixels, 0x001f where the ground is water. One mask pixel covers
	// `media_scale` background pixels (background width / mask width).
	media:       []u16,
	media_w:     i32,
	media_h:     i32,
	media_scale: i32,
}

Weapon :: struct {
	id:        Res_ID,
	using def: Wep_Def,
	spawns:    []Wep_Spawn_Def, // +0x1c0
}

// Weapon types (Wep_Def.type), compared as ids by the original.
WEP_AIR :: Res_ID{'P', 'E', 'A', 'A'}
WEP_GROUND :: Res_ID{'P', 'E', 'A', 'G'}
WEP_AUX :: Res_ID{'A', 'U', 'X', ' '}
WEP_DEFAULT_AIR :: Res_ID{'D', 'E', 'A', 'A'}
WEP_DEFAULT_GROUND :: Res_ID{'D', 'E', 'A', 'G'}

Player_Entry :: struct {
	id:  Res_ID,
	def: Player_Def,
}

// Perm float indices used by the simulation (flli "gafl").
PF_VISIBLE_GAME_WIDTH :: 0x36
PF_VISIBLE_GAME_HEIGHT :: 0x37
PF_PLAYER_APPEARS_INITIAL :: 0xa3
PF_PLAYER_APPEARS_REQUIRED :: 0xa4
PF_PLAYER_APPEARS_DELTA :: 0xa5

// Sizes of the original's permanent tables (G_Res_LoadPermData).
PERM_FLOATS :: 220 // flli "gafl"
PERM_OBJECTS :: 40 // idli "gaob"
PERM_SOUNDS :: 24 // idli "gaso"

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
	levels:       []Level_Def, // ordered by number
	weapons:      []Weapon,    // master list, in resource order
	players:      []Player_Entry,
	sprites:      []Sprite,
	perm_floats:  [PERM_FLOATS]f32,
	perm_objects: [PERM_OBJECTS]Res_ID,
	perm_sounds:  [PERM_SOUNDS]Res_ID,
}

unit_find :: proc "contextless" (d: ^Defs, id: Res_ID) -> ^Unit {
	for &u in d.units {
		if u.id == id {
			return &u
		}
	}
	return nil
}

level_by_id :: proc "contextless" (d: ^Defs, id: Res_ID) -> ^Level_Def {
	for &l in d.levels {
		if l.id == id {
			return &l
		}
	}
	return nil
}

player_def_index :: proc "contextless" (d: ^Defs, id: Res_ID) -> i32 {
	for &p, i in d.players {
		if p.id == id {
			return i32(i)
		}
	}
	return -1
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
