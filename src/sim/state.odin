package sim

// Game_Type mirrors the original's G_Game_Type enum, which G_Film records
// alongside the seed and level so a replay reconstructs the same session.
Game_Type :: enum u8 {
	Single  = 0,
	Co_Op   = 1,
}

// Session parameters fixed at start and never mutated. A film stores exactly
// these three values plus the per-frame inputs.
Session :: struct {
	seed:      u32,
	level_id:  u16,
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
	mix(&h, u64(s.rng.state))
	for i in 0 ..< MAX_PLAYERS {
		p := s.players[i]
		mix(&h, u64(p.active ? 1 : 0))
		mix(&h, u64(u32(p.x)))
		mix(&h, u64(u32(p.y)))
		mix(&h, u64(p.score))
	}
	return h
}
