package data

import "dr:sim"

// Replay ("film") resources: a fixed-size binary record, unlike the ten
// tagged-text families.
//
// Layout recovered from G_Film::Load / ::GetRandomSeed / ::GetLevelID /
// ::GetGameType / ::GetInputs / ::SetInputs in the decompilation corpus, and
// checked against all five shipped films.
//
//   +0x00  u32   version, always 10005
//   +0x04  u32   random seed
//   +0x08  4     level id (FourCC)
//   +0x0c  u8    game type (+3 bytes padding)
//   then two player tracks, stride 0x4eac:
//   +0x00  u32   frame count
//   +0x04  u32   timestamp
//   +0x08  4     level id (FourCC), "none" when the track is unused
//   +0x0c  n     one input byte per frame, at most 20000
//
// Endianness is per file. G_Film::Load compares the version and, on mismatch,
// byte-swaps exactly four field kinds: version, seed, frame count and
// timestamp. FourCCs and the game-type byte are never swapped, so they read
// identically either way. The four films in Game.pak are big-endian, authored
// on the Mac; `Data/Local/film/Last Film[last].film`, written by this Windows
// build, is little-endian.

FILM_VERSION :: 10005
FILM_SIZE :: 0x9d68
FILM_PLAYER_STRIDE :: 0x4eac
FILM_HEADER_SIZE :: 0x10
FILM_MAX_FRAMES :: 20000

// Verified: G_Player::Priv_ResetPosition selects the single-player start
// position from G_PlayerDef when the game type is 1, and the two-player start
// otherwise. The co-operative value is not yet established.
FILM_GAME_TYPE_SINGLE :: 1

Film_Error :: enum {
	None,
	Truncated,
	Bad_Version,
	Frame_Count_Too_Large,
}

Film_Track :: struct {
	frame_count: u32,
	timestamp:   u32,
	level_id:    FourCC,
}

Film :: struct {
	version:    u32,
	seed:       u32,
	level_id:   FourCC,
	game_type:  u8,
	big_endian: bool,
	tracks:     [sim.MAX_PLAYERS]Film_Track,
	// One decoded input set per frame, length = max track frame count.
	frames: []sim.Frame_Input,
}

@(private = "file")
rd_u32 :: proc(b: []byte, o: int, big: bool) -> u32 {
	if big {
		return u32(b[o]) << 24 | u32(b[o + 1]) << 16 | u32(b[o + 2]) << 8 | u32(b[o + 3])
	}
	return u32(b[o]) | u32(b[o + 1]) << 8 | u32(b[o + 2]) << 16 | u32(b[o + 3]) << 24
}

@(private = "file")
rd_fourcc :: proc(b: []byte, o: int) -> (f: FourCC) {
	copy(f[:], b[o:o + 4])
	return
}

// The seven input bits, in the order G_Film::SetInputs writes them. Each maps
// to a field index in G_Input_PlayerInputs; the semantic identity of those
// fields is still unproven, so this table is the one place to correct once
// G_Input_CachePlayerInputs and U_Prefs_GetPlayerKeyCodes are worked through.
//
// PROVISIONAL: the ordering below assumes the prefs control order is
// up, down, left, right, fire-air, fire-ground, change-weapon.
@(private = "file")
BIT_TO_BUTTON := [7]sim.Button {
	0 = .Right,       // bit 0x01 -> G_Input_PlayerInputs field 3
	1 = .Down,        // bit 0x02 -> field 1
	2 = .Up,          // bit 0x04 -> field 0
	3 = .Left,        // bit 0x08 -> field 2
	4 = .Fire_Air,    // bit 0x10 -> field 4
	5 = .Fire_Ground, // bit 0x20 -> field 5
	6 = .Change_Air,  // bit 0x40 -> field 6
}

film_buttons_from_byte :: proc "contextless" (v: u8) -> (b: sim.Buttons) {
	for i in 0 ..< 7 {
		if v & (1 << u8(i)) != 0 {
			b += {BIT_TO_BUTTON[i]}
		}
	}
	return
}

film_parse :: proc(src: []byte, allocator := context.allocator) -> (f: Film, err: Film_Error) {
	if len(src) < FILM_SIZE {
		return {}, .Truncated
	}

	// Pick the byte order the version field validates under.
	switch {
	case rd_u32(src, 0, true) == FILM_VERSION:
		f.big_endian = true
	case rd_u32(src, 0, false) == FILM_VERSION:
		f.big_endian = false
	case:
		return {}, .Bad_Version
	}

	f.version = FILM_VERSION
	f.seed = rd_u32(src, 4, f.big_endian)
	f.level_id = rd_fourcc(src, 8)
	f.game_type = src[0x0c]

	longest: u32
	for p in 0 ..< sim.MAX_PLAYERS {
		base := FILM_HEADER_SIZE + p * FILM_PLAYER_STRIDE
		t := Film_Track {
			frame_count = rd_u32(src, base, f.big_endian),
			timestamp   = rd_u32(src, base + 4, f.big_endian),
			level_id    = rd_fourcc(src, base + 8),
		}
		if t.frame_count > FILM_MAX_FRAMES {
			return {}, .Frame_Count_Too_Large
		}
		f.tracks[p] = t
		longest = max(longest, t.frame_count)
	}

	f.frames = make([]sim.Frame_Input, longest, allocator)
	for p in 0 ..< sim.MAX_PLAYERS {
		base := FILM_HEADER_SIZE + p * FILM_PLAYER_STRIDE + 0x0c
		for i in 0 ..< int(f.tracks[p].frame_count) {
			f.frames[i][p] = film_buttons_from_byte(src[base + i])
		}
	}
	return f, .None
}

film_destroy :: proc(f: ^Film, allocator := context.allocator) {
	delete(f.frames, allocator)
	f^ = {}
}

// Convert to the simulation's replay type. The session is what
// G_Film::StartPlayback hands the game: level, game type and seed.
film_to_sim :: proc(f: Film) -> sim.Film {
	return sim.Film{
		session = sim.Session{
			seed      = f.seed,
			level_id  = sim.Level_ID(f.level_id),
			game_type = f.game_type == FILM_GAME_TYPE_SINGLE ? .Single : .Co_Op,
		},
		frames = f.frames,
	}
}
