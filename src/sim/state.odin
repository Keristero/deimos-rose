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
// the first three plus the per-frame inputs; `easy` and `loadout` are not
// the original's, and no film sets them.
Session :: struct {
	seed:      u32,
	level_id:  Level_ID,
	game_type: Game_Type,
	easy:      bool, // easy mode: a reward screen after every level (reward.odin)
	loadout:   bool, // New Weapons: the new weapons, and a loadout screen each stage (loadout.odin)
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
	debris:       Debris,
	sounds:       Sound_Queue,    // this step's sound events, for presentation
	particles:    Particle_Queue, // this step's particle bursts, for presentation
	stamps:       Stamp_Queue,    // this step's marks on the terrain
	blurs:        Blur_Queue,     // this step's new motion-blur ghosts
	notice:       Notice_State,   // the pending on-screen notice, if any
	notices:      Notice_Queue,   // this step's new notices, for presentation
	accuracy_targets:   i32,  // DAT_004e4856
	accuracy_destroyed: i32,  // DAT_004e485a
	accuracy_reward_this_level: bool, // DAT_004e4828
	perfect_level: bool,        // DAT_004e4827: this level ended at 100%
	levels_played: i32,         // DAT_004e482a: levels started this session
	player1_seen_playing: bool, // FUN_00420280's first argument
	level_ending: bool,         // DAT_004e4855
	game_over:    bool,         // DAT_004e4826: no player left in the game
	game_over_notice: bool,     // FUN_00420280's third argument: the game-over banner has been spawned
	level_end:    Level_End,
	// Netplay pause (session_step): new content, not the original's
	// G_Interface_PauseGame, which lives outside the simulation entirely
	// (game/flow.odin's .Paused, still what single-player uses).
	paused:       bool,
	pause_held:   [MAX_PLAYERS]bool, // each player's Pause bit last step, for edge detection
	reward:       Reward,            // easy mode's reward screen, between levels
	loadout:      Loadout,           // New Weapons' loadout screen, early in each level
	// The first original function reached that is not ported yet, by
	// address; 0 while the port covers everything run so far. `gaps` keeps
	// each distinct site with the film step it was first reached at.
	unported:     Site,
	events:       ^Event_Log, // debugging aid; see events.odin
	gaps:         [32]Gap,
	gap_count:    int,
}

Gap :: struct {
	site: Site,
	step: i32,
}

// Records that execution reached code the port does not cover yet. The
// simulation carries on, but from here on it can differ from the original;
// `oracle:diff` reports the site.
unported :: proc "contextless" (s: ^State, site: Site) {
	if s.unported == 0 {
		s.unported = site
	}
	for g in s.gaps[:s.gap_count] {
		if g.site == site {
			return
		}
	}
	if s.gap_count < len(s.gaps) {
		s.gaps[s.gap_count] = {site, s.film_cursor[0]}
		s.gap_count += 1
	}
}

// G_Game_Play's set-up for one session: srand(seed), both players, the
// first level.
init :: proc(s: ^State, session: Session, defs: ^Defs, log: ^Draw_Log = nil, events: ^Event_Log = nil) {
	s^ = State{}
	s.session = session
	s.defs = defs
	s.events = events
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
	s.accuracy_targets = 0
	s.accuracy_destroyed = 0
	// FUN_004208d0: the tally resets, but not the count of levels finished
	// at 100%, nor `all_done`/`complete`, which belong to the session.
	l := &s.level_end
	l.started, l.started_time = false, 0
	l.state, l.state_time, l.count_time = 0, 0, 0
	l.fade = 0x20
	l.percent, l.bonus, l.bonus_step = 0, 0, 0
	l.perfect, l.perfect_count = false, 0
	// A level finished at 100% accuracy earns the bonus pickup on the next
	// one, once (G_Game_GroundAccuracy_CheckForRewardThisLevel).
	s.accuracy_reward_this_level = s.perfect_level
	s.perfect_level = false
	s.levels_played += 1
	for &p in s.players {
		player_level_reset(s, &p, s.time)
	}
	s.debris.count = 0 // G_Debris_ResetAtLevelStart
	bgnd_reset(s, s.level)
	eg_reset(s, s.level)
	bgnd_initial_spawns(s)

	// The level's title notice unit, centred in the play area. The loadout
	// screen waits for it to go.
	s.loadout.shown = false
	s.loadout.title = NO_REF
	notice := s.defs.perm_objects[s.level_number + 9]
	if notice != NONE {
		req := spawn_request(notice)
		req.loc = {
			s.defs.perm_floats[PF_VISIBLE_GAME_WIDTH] / 2,
			s.defs.perm_floats[PF_VISIBLE_GAME_HEIGHT] / 2,
		}
		s.loadout.title = eg_request_spawn(s, req)
	}
}

// Moves to the next level in list order once level_end.complete is true and
// this was not the last one (level_end.all_done), keeping the session's
// score/money the same way the original does: G_LevelSelect_GetStartingLevelID
// -FromUser only ever picks the *first* level of a new session
// (G_LevelSelect_IsRunning has one caller, the title flow) -- levels within a
// session always play in list order, so there is nothing to choose here.
// `defs.levels` is ordered by number and level_number is 1-based, so the next
// entry is simply the array index at the current number.
level_advance :: proc(s: ^State) -> bool {
	next := int(s.level_number)
	if next >= len(s.defs.levels) {
		return false
	}
	s.level = &s.defs.levels[next]
	s.level_number = s.level.number
	// level_start leaves `complete` alone (FUN_004208d0 does not touch it),
	// so it has to be consumed here: left set, flow_step saw the next level
	// as already complete on its very first step and chained through every
	// remaining level in as many steps. `level_ending` likewise has no reset
	// anywhere in the port, and left set it keeps players invulnerable and
	// blocks can_be_spawned_only_when_players_active units for the rest of
	// the session. Provisional: where the original clears DAT_004e4825 and
	// DAT_004e4855 between levels has not been traced -- the effect (both
	// false at the start of every level) is what a playable session needs.
	s.level_end.complete = false
	s.level_ending = false
	level_start(s)
	return true
}

Level_Transition :: enum u8 {
	None,         // still playing this level
	Game_Over,    // the last player left play
	Advanced,     // this level was counted; the next one has started
	All_Complete, // the last level of the list was counted
}

// What the session does after a step: carry on, game over, the next level or
// the end of the list. game_over wins over complete, see flow_step.
level_transition :: proc(s: ^State) -> Level_Transition {
	if s.game_over {
		return .Game_Over
	}
	if !s.level_end.complete || s.reward.active {
		return .None
	}
	return level_advance(s) ? .Advanced : .All_Complete
}

// One step of a played session -- live, local or netplay -- as opposed to
// step alone, which films and the oracle tools replay. Adds the two things a
// session needs that FUN_00420280 does not do: the netplay pause, and the
// move to the next level.
//
// The level change has to happen *inside* whatever the rollback session
// steps and snapshots. It used to be applied by game/flow.odin after
// rollback_session_advance returned: the snapshot for that frame held the
// finished old level, and any rollback reaching back past the change
// resimulated the old level without ever moving on, then flow advanced it a
// second time at whatever frame it happened to notice -- so the two peers
// changed level on different frames and desynced. Here, it is a pure
// function of the state and inputs like the rest of the step, and a
// resimulation reproduces it on the same frame.
//
// While paused, only the frame count advances (the rollback ring is keyed
// on it, and inputs keep flowing so either player can unpause); game time,
// the RNG and every entity stand still.
//
// In easy mode a counted level opens the reward screen (reward.odin) on the
// step it is counted, and the move to the next level waits for it to close.
// It pauses the game the same way, and a pause pauses it in turn. New
// Weapons' loadout screen (loadout.odin) opens early in a level the same
// way, on the step the level's title has gone.
session_step :: proc(s: ^State, input: Frame_Input, film: ^Film = nil) -> Level_Transition {
	toggle := false
	for i in 0 ..< MAX_PLAYERS {
		held := .Pause in input[i]
		if held && !s.pause_held[i] {
			toggle = true // both pressing on the same frame still toggles once
		}
		s.pause_held[i] = held
	}
	if toggle {
		s.paused = !s.paused
	}
	if s.paused {
		clear_step_events(s) // nothing happened this step; do not replay last step's
		s.frame += 1
		return .None
	}
	game_input := input
	for &b in game_input {
		b -= {.Pause}
	}
	if s.reward.active {
		if reward_step(s, game_input) {
			return .None
		}
		return level_transition(s)
	}
	if s.loadout.active {
		loadout_step(s, game_input)
		return .None
	}
	step(s, game_input, film)
	if reward_due(s) && reward_begin(s, game_input) {
		return .None
	}
	if loadout_due(s) && loadout_begin(s, game_input) {
		return .None
	}
	return level_transition(s)
}

// Whether play stands still this step for a pause or a between-play screen:
// the presentation holds its own effects still to match.
session_frozen :: proc "contextless" (s: ^State) -> bool {
	return s.paused || s.reward.active || s.loadout.active
}

// This step's presentation events start empty; step, a paused session_step
// and the reward screen all begin here.
clear_step_events :: proc "contextless" (s: ^State) {
	s.sounds.count = 0
	s.particles.count = 0
	s.stamps.count = 0
	s.blurs.count = 0
	s.notices.count = 0
}

// One game step: FUN_00420280, then the game-time advance in G_Game_Play.
// `input` drives live play; with a film, players read the film instead,
// one frame per step they spend in play.
step :: proc(s: ^State, input: Frame_Input, film: ^Film = nil) {
	clear_step_events(s)
	if !s.player1_seen_playing && s.players[0].state == .Playing {
		s.player1_seen_playing = true
	}
	// G_Notice_Process, G_Particle_Process and G_MotionBlur_Process do not
	// draw; G_Debris_Process moves the ground wreckage with the scroll.
	notice_process(s)
	debris_process(s)
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
		s.game_over = true
		// FUN_00420280 LAB_0042037a: the first step no player is left in
		// game spawns the Notice_GameOver banner (perm object 0x18) once, at
		// screen centre -- the same position formula level_end_begin uses
		// for Notice_LevelEnd/AllLevelsCompleted. Confirmed 0x18 is
		// Notice_GameOver, not guessed: assets/data/idli/gaob.json lists
		// perm objects in order, and index 0x16 Notice_LevelEnd / 0x17
		// Notice_AllLevelsCompleted / 0x18 Notice_GameOver / 0x19
		// RandomBonus_1 lines up exactly with level_end.odin's own 0x16/0x17
		// and destroy.odin's 0x19..0x22 RandomBonus comment. This spawn
		// draws from the RNG like any other, so a real session that runs out
		// of lives needs it for the replay to stay in sync -- no shipped
		// demo film reaches game over, so oracle:diff never exercised this
		// gap before.
		if !s.game_over_notice {
			notice := s.defs.perm_objects[0x18]
			if notice != NONE {
				req := spawn_request(notice)
				req.loc = {
					s.defs.perm_floats[PF_VISIBLE_GAME_WIDTH] / 2,
					s.defs.perm_floats[PF_VISIBLE_GAME_HEIGHT] / 2,
				}
				eg_request_spawn(s, req)
			}
			s.game_over_notice = true
		}
	}
	if bgnd_process(s) {
		level_end_step(s, s.time)
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
	// Which level, and whether it has ended or play is paused: two peers on
	// different levels at the same time value must not hash alike.
	mix(&h, u64(s.level_number))
	mix(&h, u64(s.level_end.complete ? 1 : 0) | u64(s.paused ? 2 : 0))
	for &p in s.players {
		mix(&h, u64(p.active ? 1 : 0))
		mix(&h, u64(p.state))
		mix(&h, u64(transmute(u32)p.loc.x))
		mix(&h, u64(transmute(u32)p.loc.y))
	}
	// Easy mode's own state. Only then: a session without it hashes as it
	// always has.
	if s.session.easy {
		r := &s.reward
		mix(&h, u64(r.active ? 1 : 0) | u64(r.count) << 8 | u64(r.ready_time) << 16)
		for i in 0 ..< MAX_PLAYERS {
			mix(&h, u64(r.cursor[i]) | u64(r.locked[i] ? 1 : 0) << 32)
			p := &s.players[i]
			for lv in p.passives {
				mix(&h, u64(lv))
			}
			mix(&h, u64(p.regen_wait) | u64(p.regen_acc) << 32)
		}
	}
	// New Weapons' own state, likewise only then.
	if s.session.loadout {
		l := &s.loadout
		mix(&h, u64(l.active ? 1 : 0) | u64(l.shown ? 2 : 0) | u64(l.ready_time) << 8)
		for i in 0 ..< MAX_PLAYERS {
			b := &l.boards[i]
			mix(&h, u64(b.row) | u64(b.col) << 8 | u64(b.hold_row) << 16 | u64(b.hold_col) << 24 |
				u64(b.holding ? 1 : 0) << 32 | u64(b.ready ? 1 : 0) << 33)
			for row in b.cells {
				for w in row {
					mix(&h, u64(u32(w)))
				}
			}
			wh := &s.players[i].weapons
			for w in wh.loadout {
				mix(&h, u64(u32(w)))
			}
			for w in wh.spare {
				mix(&h, u64(u32(w)))
			}
		}
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
