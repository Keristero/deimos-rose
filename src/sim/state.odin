package sim

import "base:runtime"

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
// in the entity component system `ecs` points at (D39): the session's
// singletons (components.odin), the players, the entity pool and its groups
// (world.odin). The rest
// here is not state:
// - `session` is fixed at start;
// - `defs` points at read-only data;
// - the queues are what the last step did, for presentation to show, and
//   no step reads them back;
// - `draws`, `events` and the unported sites are debugging records.
// state_write and state_read copy a state, for rollback and reconnection.
State :: struct {
	session:      Session,
	defs:         ^Defs,
	ecs:          ^Ecs,
	sounds:       Sound_Queue,    // this step's sound events, for presentation
	particles:    Particle_Queue, // this step's particle bursts, for presentation
	stamps:       Stamp_Queue,    // this step's marks on the terrain
	blurs:        Blur_Queue,     // this step's new motion-blur ghosts
	beams:        Beam_Queue,     // this step's laser shots, for presentation (beam.odin)
	notices:      Notice_Queue,   // this step's new notices, for presentation
	// Optional record of every RandomInt/RandomFloat call, for diffing
	// against the original's gdb trace (see oracle/). nil in normal play
	// and netplay. Tracing is a single-timeline debugging aid: rollback
	// leaves it alone.
	draws:        ^Draw_Log,
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
		s.gaps[s.gap_count] = {site, single(s, Film_Cursor).reads[0]}
		s.gap_count += 1
	}
}

// G_Game_Play's set-up for one session: srand(seed), both players, the
// first level.
//
// The state's world is made on first use and kept, emptied, for the next
// session; destroy frees it.
init :: proc(s: ^State, session: Session, defs: ^Defs, log: ^Draw_Log = nil, events: ^Event_Log = nil) {
	world := s.ecs
	s^ = State{}
	if world == nil {
		world = ecs_create()
	} else {
		ecs_clear(world)
	}
	s.ecs = world
	s.session = session
	s.defs = defs
	s.events = events
	s.draws = log
	add_singletons(s)
	for i in 0 ..< i32(MAX_PLAYERS) {
		ecs_set_components(s.ecs, player_entity(i), player_components())
		ecs_set_components(s.ecs, crosshair_entity(i), crosshair_components())
	}
	single(s, Rng).next = session.seed
	level := level_by_id(defs, session.level_id)
	if level == nil {
		unported(s, 1) // unknown level id
		return
	}
	single(s, Level_Info).number = level.number
	for i in 0 ..< i32(MAX_PLAYERS) {
		player_setup(s, player_at(s, i), i, session.game_type)
	}
	level_start(s)
}

destroy :: proc(s: ^State) {
	ecs_destroy(s.ecs)
	s.ecs = nil
}

// Appends everything a copy of s needs to buf: the state's own fields and
// its world. Pointers are written as they are and state_read replaces them,
// so a copy can go to another process.
state_write :: proc(s: ^State, buf: ^[dynamic]byte) {
	start := len(buf)
	append(buf, ..([^]u8)(s)[:size_of(State)])
	// Addresses mean nothing to the reader; send zeroes.
	fields := ([^]u8)(&buf[start])
	for off in ([?]uintptr{offset_of(State, defs), offset_of(State, ecs), offset_of(State, draws), offset_of(State, events)}) {
		runtime.mem_zero(&fields[off], size_of(rawptr))
	}
	ecs_write(s.ecs, buf)
}

// Makes s the state state_write wrote into data. s keeps its own world,
// definitions, draw log and event log. Fails, changing nothing, if data is
// not a state from this build.
state_read :: proc(s: ^State, data: []byte) -> bool {
	if len(data) < size_of(State) {
		return false
	}
	plain := new(State)
	defer free(plain)
	runtime.mem_copy_non_overlapping(plain, raw_data(data), size_of(State))
	rest, ok := ecs_read(s.ecs, data[size_of(State):])
	if !ok || len(rest) != 0 {
		return false
	}
	restore_plain(s, plain)
	return true
}

// s^ = plain, keeping what s points at.
@(private)
restore_plain :: proc(s: ^State, plain: ^State) {
	defs, world, draws, events := s.defs, s.ecs, s.draws, s.events
	s^ = plain^
	s.defs, s.ecs, s.draws, s.events = defs, world, draws, events
}

// FUN_0041fc80: the start of a level.
level_start :: proc(s: ^State) {
	single(s, Clock).time = 0
	acc := single(s, Accuracy)
	acc.targets = 0
	acc.destroyed = 0
	// FUN_004208d0: the tally resets, but not the count of levels finished
	// at 100%, nor `all_done`/`complete`, which belong to the session.
	l := single(s, Level_End)
	l.started, l.started_time = false, 0
	l.state, l.state_time, l.count_time = 0, 0, 0
	l.fade = 0x20
	l.percent, l.bonus, l.bonus_step = 0, 0, 0
	l.perfect, l.perfect_count = false, 0
	// A level finished at 100% accuracy earns the bonus pickup on the next
	// one, once (G_Game_GroundAccuracy_CheckForRewardThisLevel).
	acc.reward_this_level = acc.perfect_level
	acc.perfect_level = false
	single(s, Level_Info).played += 1
	for p in players_of(s) {
		player_level_reset(s, p, 0)
	}
	single(s, Debris).count = 0 // G_Debris_ResetAtLevelStart
	bgnd_reset(s, level_def(s))
	eg_reset(s, level_def(s))
	bgnd_initial_spawns(s)

	// The level's title notice unit, centred in the play area. The loadout
	// screen waits for it to go.
	single(s, Loadout).shown = false
	single(s, Loadout).title = NO_REF
	notice := s.defs.perm_objects[level_number_of(s) + 9]
	if notice != NONE {
		req := spawn_request(notice)
		req.loc = {
			s.defs.perm_floats[PF_VISIBLE_GAME_WIDTH] / 2,
			s.defs.perm_floats[PF_VISIBLE_GAME_HEIGHT] / 2,
		}
		title := eg_request_spawn(s, req)
		single(s, Loadout).title = title
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
	info := single(s, Level_Info)
	next := int(info.number)
	if next >= len(s.defs.levels) {
		return false
	}
	info.number = s.defs.levels[next].number
	// level_start leaves `complete` alone (FUN_004208d0 does not touch it),
	// so it has to be consumed here: left set, flow_step saw the next level
	// as already complete on its very first step and chained through every
	// remaining level in as many steps. `level_ending` likewise has no reset
	// anywhere in the port, and left set it keeps players invulnerable and
	// blocks can_be_spawned_only_when_players_active units for the rest of
	// the session. Provisional: where the original clears DAT_004e4825 and
	// DAT_004e4855 between levels has not been traced -- the effect (both
	// false at the start of every level) is what a playable session needs.
	single(s, Level_End).complete = false
	info.ending = false
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
	if single(s, Game_Status).game_over {
		return .Game_Over
	}
	if !single(s, Level_End).complete || single(s, Reward).active {
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
		if held && !single(s, Pause).held[i] {
			toggle = true // both pressing on the same frame still toggles once
		}
		single(s, Pause).held[i] = held
	}
	if toggle {
		single(s, Pause).paused = !single(s, Pause).paused
	}
	if single(s, Pause).paused {
		clear_step_events(s) // nothing happened this step; do not replay last step's
		single(s, Clock).frame += 1
		return .None
	}
	game_input := input
	for &b in game_input {
		b -= {.Pause}
	}
	if single(s, Reward).active {
		if reward_step(s, game_input) {
			return .None
		}
		return level_transition(s)
	}
	if single(s, Loadout).active {
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
	return single(s, Pause).paused || single(s, Reward).active || single(s, Loadout).active
}

// This step's presentation events start empty; step, a paused session_step
// and the reward screen all begin here.
clear_step_events :: proc "contextless" (s: ^State) {
	s.sounds.count = 0
	s.particles.count = 0
	s.stamps.count = 0
	s.blurs.count = 0
	s.beams.count = 0
	s.notices.count = 0
}

// One game step: FUN_00420280, then the game-time advance in G_Game_Play.
// `input` drives live play; with a film, players read the film instead,
// one frame per step they spend in play.
step :: proc(s: ^State, input: Frame_Input, film: ^Film = nil) {
	clear_step_events(s)
	if !single(s, Game_Status).player1_seen_playing && player_at(s, 0).state == .Playing {
		single(s, Game_Status).player1_seen_playing = true
	}
	// G_Notice_Process, G_Particle_Process and G_MotionBlur_Process do not
	// draw; G_Debris_Process moves the ground wreckage with the scroll.
	notice_process(s)
	debris_process(s)
	for i in 0 ..< MAX_PLAYERS {
		player_process(s, player_at(s, i), single(s, Clock).time, input[i], film)
	}
	// G_ScoreBar_Process is presentation.

	any_in_game := false
	for p in players_of(s) {
		if p.active {
			any_in_game = true
		}
	}
	if !any_in_game {
		single(s, Game_Status).game_over = true
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
		if !single(s, Game_Status).game_over_notice {
			notice := s.defs.perm_objects[0x18]
			if notice != NONE {
				req := spawn_request(notice)
				req.loc = {
					s.defs.perm_floats[PF_VISIBLE_GAME_WIDTH] / 2,
					s.defs.perm_floats[PF_VISIBLE_GAME_HEIGHT] / 2,
				}
				eg_request_spawn(s, req)
			}
			single(s, Game_Status).game_over_notice = true
		}
	}
	if bgnd_process(s) {
		level_end_step(s, single(s, Clock).time)
	}
	if eg_process(s, single(s, Clock).time) {
		bgnd_stop(s)
	} else {
		bgnd_resume(s)
	}
	single(s, Clock).time += 1
	single(s, Clock).frame += 1
}

// Order-sensitive FNV-1a over the state, used to detect divergence between a
// replayed film and a live run, and between rollback peers: the whole world,
// which is all of the state that matters.
checksum :: proc(s: ^State) -> u64 {
	h := hasher()
	ecs_hash(s.ecs, &h)
	return h.sum
}
