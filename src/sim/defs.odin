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

// The original stores colours as 1555 pixels (U_Token_GetColor reads them
// straight into a u16); our records keep the RGB triple, so pack when a
// packed value is needed.
color_1555 :: proc "contextless" (c: Color) -> u16 {
	return u16(c.r >> 3) << 10 | u16(c.g >> 3) << 5 | u16(c.b >> 3)
}

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

// G_Entity::GetFrameForAngle: the first frame of the direction nearest a
// heading (degrees). A def-only question, so the level editor can show a
// placement facing the way it will spawn.
state_frame_for_angle :: proc "contextless" (st: ^Unit_State, angle: i32) -> i32 {
	dirs := max(st.num_directions, 1)
	f := f32(angle) / f32(360 / dirs)
	i := trunc_i32(f)
	if f - f32(i) >= 0.5 {
		i += 1
	}
	if i < 0 {
		i = dirs - 1
	} else if i > dirs - 1 {
		i = 0
	}
	return i * st.frames_per_direction
}

// A ground placement's x is in map columns, 32 more than the play field's
// (DAT_004e34b8); an air placement's is already in play-field columns.
GROUND_PLACEMENT_SHIFT :: 32

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
	// The level's name_STR, as Level Select shows it: "Mariner Valley".
	name:       string,
	identifier: string,
	// 1-based play order within its campaign. G_Level_BuildInfoList numbers
	// the original's levels by matching each level's identifier against
	// twelve encrypted names built into the executable (0x4e7ba9): Lucena
	// (le07) is 1, Yippe (le06) 2, Vista (le02) 3, Swoop (le08) 4, ... The
	// four demos play levels 1-4 in order. A campaign plugin lists its own.
	number:     i32,
	// Not the original's: whose level this is (D53). CORE for the
	// original's twelve, which the Classic Levels plugin holds.
	campaign:   Plugin_ID,
	// Not the original's: the weapons a player starts this level with, in
	// place of the ones its number brings (D54). Zero when the level names
	// none, as every original does.
	start_air:    Res_ID,
	start_ground: Res_ID,
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
	// Not the original's: set only on a plugin's own weapons
	// (plugins/<plugin name>/data, docs/new-weapons.md), which exist only
	// in a session with that plugin on (weapon_allowed).
	extra:  bool,
	plugin: Plugin_ID, // whose they are, when extra
	// The values of the keys plugins register (def_keys.odin), by Weapon_Key.
	keys:  [MAX_WEAPON_KEYS]u32,
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
PF_ENTITY_HIT_DELAY :: 0xa7 // Entity_HitDelay: steps after a hit in which an entity takes no other

// The fewest steps between two hits one entity takes: one more than the
// hit delay (G_Entity::Hit), so 2 with the original's data.
hit_gap :: #force_inline proc "contextless" (s: ^State) -> i32 {
	return trunc_i32(s.defs.perm_floats[PF_ENTITY_HIT_DELAY]) + 1
}

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
	levels:       []Level_Def, // by campaign, CORE's first, then by number (campaign_levels)
	weapons:      []Weapon,    // master list, in resource order
	players:      []Player_Entry,
	sprites:      []Sprite,
	perm_floats:  [PERM_FLOATS]f32,
	perm_objects: [PERM_OBJECTS]Res_ID,
	perm_sounds:  [PERM_SOUNDS]Res_ID,
	// Not the original's: the plugins whose own content loaded
	// (data.extra_defs_load).
	content:      Mods,
}

unit_find :: proc "contextless" (d: ^Defs, id: Res_ID) -> ^Unit {
	for &u in d.units {
		if u.id == id {
			return &u
		}
	}
	return nil
}

// A campaign's levels, in play order: the run of `d.levels` it holds.
// Empty for a campaign with none.
campaign_levels :: proc "contextless" (d: ^Defs, campaign: Plugin_ID) -> []Level_Def {
	first, end := -1, len(d.levels)
	for l, i in d.levels {
		if l.campaign == campaign && first < 0 {
			first = i
		} else if l.campaign != campaign && first >= 0 {
			end = i
			break
		}
	}
	return first < 0 ? nil : d.levels[first:end]
}

level_by_id :: proc "contextless" (d: ^Defs, campaign: Plugin_ID, id: Res_ID) -> ^Level_Def {
	for &l in campaign_levels(d, campaign) {
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

