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

// Verified in G_Game_Play, which switches on the game type to label the run:
// case 1 -> "1 Player", case 2 -> "2 Player".
FILM_GAME_TYPE_SINGLE :: 1
FILM_GAME_TYPE_CO_OP :: 2

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

// The seven input bits, in the order G_Film::SetInputs writes them.
//
// Resolved through three pieces of evidence rather than assumed:
//
//  1. G_Film::SetInputs maps each bit to a field index in
//     G_Input_PlayerInputs: 0x01->3, 0x02->1, 0x04->0, 0x08->2, 0x10->4,
//     0x20->5, 0x40->6.
//  2. G_Input_CachePlayerInputs maps U_Prefs_PlayerControlCodes entry i to
//     those same field indices: 0->0, 1->3, 2->1, 3->2, 4->5, 5->4, 6->6.
//  3. The "Edit Key Controls" dialog (resource 102, read out of .rsrc) lists
//     the control entries in order: Move Up, Move Down, Move Left, Move Right,
//     Fire Air, Fire Ground, Switch Weapon.
//
// Composing those gives the mapping below. Note that up/down and left/right
// are not adjacent in the on-disk bit order, and that fire-air and fire-ground
// are transposed relative to the prefs order -- which is exactly why this
// needed proving instead of guessing.
@(private = "file")
BIT_TO_BUTTON := [7]sim.Button {
	0 = .Down,        // bit 0x01 -> input field 3 -> "Move Down"
	1 = .Left,        // bit 0x02 -> field 1       -> "Move Left"
	2 = .Up,          // bit 0x04 -> field 0       -> "Move Up"
	3 = .Right,       // bit 0x08 -> field 2       -> "Move Right"
	4 = .Fire_Ground, // bit 0x10 -> field 4       -> "Fire Ground"
	5 = .Fire_Air,    // bit 0x20 -> field 5       -> "Fire Air"
	6 = .Change_Air,  // bit 0x40 -> field 6       -> "Switch Weapon"
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
