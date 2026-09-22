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
Level_ID :: Res_ID

level_id :: proc "contextless" (s: string) -> Level_ID {
	return res_id(s)
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
// `defs` points at read-only data and is not part of the state proper.
State :: struct {
	session:      Session,
	defs:         ^Defs,
	level:        ^Level_Def,
	level_number: i32,        // DAT_004e482e
	time:         i32,        // DAT_004e4836: game steps this level
	frame:        u32,        // steps taken this session
	rng:          Rand,
	film_cursor:  [MAX_PLAYERS]i32, // G_Film's per-player read positions
	players:      [MAX_PLAYERS]Player,
	world:        World,
	bgnd:         Bgnd,
	sounds:       Sound_Queue, // this step's sound events, for presentation
	player1_seen_playing: bool, // FUN_00420280's first argument
	level_ending: bool,         // DAT_004e4855
	// The first original function reached that is not ported yet, by
	// address; 0 while the port covers everything run so far.
	unported:     Site,
}

// Records that execution reached code the port does not cover yet. The
// simulation carries on, but from here on it can differ from the original;
// `oracle:diff` reports the site.
unported :: proc "contextless" (s: ^State, site: Site) {
	if s.unported == 0 {
		s.unported = site
	}
}

// G_Game_Play's set-up for one session: srand(seed), both players, the
// first level.
init :: proc(s: ^State, session: Session, defs: ^Defs, log: ^Draw_Log = nil) {
	s^ = State{}
	s.session = session
	s.defs = defs
	s.rng = rand_init(session.seed, log)
	s.level = level_by_id(defs, session.level_id)
	if s.level == nil {
		unported(s, 1) // unknown level id
		return
	}
	s.level_number = s.level.number
	for i in 0 ..< MAX_PLAYERS {
		player_setup(s, &s.players[i], i32(i), session.game_type)
	}
	level_start(s)
}

// FUN_0041fc80: the start of a level.
level_start :: proc(s: ^State) {
	s.time = 0
	for &p in s.players {
		player_level_reset(s, &p, s.time)
	}
	bgnd_reset(s, s.level)
	eg_reset(s, s.level)
	bgnd_initial_spawns(s)

	// The level's title notice unit, centred in the play area.
	notice := s.defs.perm_objects[s.level_number + 9]
	if notice != NONE {
		req := spawn_request(notice)
		req.loc = {
			s.defs.perm_floats[PF_VISIBLE_GAME_WIDTH] / 2,
			s.defs.perm_floats[PF_VISIBLE_GAME_HEIGHT] / 2,
		}
		eg_request_spawn(s, req)
	}
}

// One game step: FUN_00420280, then the game-time advance in G_Game_Play.
// `input` drives live play; with a film, players read the film instead,
// one frame per step they spend in play.
step :: proc(s: ^State, input: Frame_Input, film: ^Film = nil) {
	s.sounds.count = 0
	if !s.player1_seen_playing && s.players[0].state == .Playing {
		s.player1_seen_playing = true
	}
	// G_Notice_Process, G_Debris_Process, G_Particle_Process,
	// G_MotionBlur_Process: nothing they do draws yet (see notice.odin).
	notice_process(s)
	for i in 0 ..< MAX_PLAYERS {
		player_process(s, &s.players[i], s.time, input[i], film)
	}
	// G_ScoreBar_Process is presentation.

	any_in_game := false
	for &p in s.players {
		if p.active {
			any_in_game = true
		}
	}
	if !any_in_game {
		unported(s, 0x42037a) // game over
	}
	if bgnd_process(s) {
		s.level_ending = true
		unported(s, 0x4203d0) // end of level
	}
	if eg_process(s, s.time) {
		bgnd_stop(s)
	} else {
		bgnd_resume(s)
	}
	s.time += 1
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
	mix(&h, u64(s.time))
	mix(&h, u64(s.rng.next))
	for &p in s.players {
		mix(&h, u64(p.active ? 1 : 0))
		mix(&h, u64(p.state))
		mix(&h, u64(transmute(u32)p.loc.x))
		mix(&h, u64(transmute(u32)p.loc.y))
	}
	w := &s.world
	mix(&h, u64(w.used_count))
	for used, i in w.entity_used {
		if !used {
			continue
		}
		e := &w.entities[i]
		mix(&h, u64(e.number))
		mix(&h, u64(e.state))
		mix(&h, u64(transmute(u32)e.loc.x))
		mix(&h, u64(transmute(u32)e.loc.y))
	}
	return h
}
