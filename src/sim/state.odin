package sim

// Game_Type mirrors the original's G_Game_Type enum, which G_Film records
// alongside the seed and level so a replay reconstructs the same session.
//
// Both values are verified. G_Game_Play switches on the game type to label the
// session: case 1 -> "1 Player", case 2 -> "2 Player". Corroborated by
// G_Player::Priv_ResetPosition, which reads the single-player start position
// out of G_PlayerDef when the value is 1 and the two-player start otherwise.
Game_Type :: enum u8 {
	Single = 1,
	Co_Op  = 2,
}

// Levels are addressed by four-byte resource id ("le01" ... "le12"), not by
// index. "none" is the canonical empty id.
Level_ID :: distinct [4]u8

level_id :: proc "contextless" (s: string) -> (id: Level_ID) {
	for i in 0 ..< 4 {
		id[i] = i < len(s) ? s[i] : ' '
	}
	return
}

// Session parameters fixed at start and never mutated. A film stores exactly
// these three values plus the per-frame inputs.
Session :: struct {
	seed:      u32,
	level_id:  Level_ID,
	game_type: Game_Type,
}

// The complete simulation state. Everything that affects future frames lives
// here and nowhere else, so that save/restore for rollback is a plain copy.
State :: struct {
	session: Session,
	frame:   u32,
	rng:     Rand,
	prev:    Frame_Input,
	players: [MAX_PLAYERS]Player,
}

// Placeholder player record. Phase 4 replaces this with the real model
// recovered from G_Player (54 functions) and G_PlayerDef.
Player :: struct {
	active: bool,
	x, y:   i32,
	score:  u32,
}

init :: proc "contextless" (s: ^State, session: Session) {
	s^ = State{}
	s.session = session
	s.rng = rand_init(session.seed)
	count := session.game_type == .Co_Op ? 2 : 1
	for i in 0 ..< count {
		s.players[i] = Player{active = true, x = 208, y = 400}
	}
}

// Advance exactly one frame. Pure: same state plus same input always yields
// the same next state.
step :: proc "contextless" (s: ^State, input: Frame_Input) {
	for i in 0 ..< MAX_PLAYERS {
		p := &s.players[i]
		if !p.active {
			continue
		}
		b := input[i]
		if .Left  in b { p.x -= 2 }
		if .Right in b { p.x += 2 }
		if .Up    in b { p.y -= 2 }
		if .Down  in b { p.y += 2 }
		// Clamped to the original 416x480 play-field described by the
		// terrain/background runtime.
		p.x = clamp(p.x, 0, 415)
		p.y = clamp(p.y, 0, 479)
	}
	s.prev = input
	s.frame += 1
}

// Order-sensitive FNV-1a over the state, used to detect divergence between a
// replayed film and a live run, and between rollback peers.
checksum :: proc "contextless" (s: ^State) -> u64 {
	h: u64 = 0xcbf29ce484222325
	mix :: proc "contextless" (h: ^u64, v: u64) {
		x := v
		for _ in 0 ..< 8 {
			h^ ~= x & 0xff
			h^ *= 0x100000001b3
			x >>= 8
		}
	}
	mix(&h, u64(s.frame))
	mix(&h, u64(s.rng.next))
	for i in 0 ..< MAX_PLAYERS {
		p := s.players[i]
		mix(&h, u64(p.active ? 1 : 0))
		mix(&h, u64(u32(p.x)))
		mix(&h, u64(u32(p.y)))
		mix(&h, u64(p.score))
	}
	return h
}
