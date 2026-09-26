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
// the first three plus the per-frame inputs; `mods` is not the original's,
// and no film sets it.
Session :: struct {
	seed:      u32,
	level_id:  Level_ID,
	game_type: Game_Type,
	mods:      Mods, // the session plugins that run (plugins.odin), dependencies included
}

// The complete simulation state. Everything that affects future frames lives
// in the entity component system `ecs` points at (D39): the session's
// singletons (components_session.odin), the players (components_player.odin),
// the entity pool and its groups (components_entity.odin). The rest
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
	prefabs:      ^Prefabs, // derived from defs and the session's plugins; not state (prefabs.odin)
	schedule:     Schedule, // the systems this session runs, in order (systems.odin, sim/core)
	sounds:       Sound_Queue,    // this step's sound events, for presentation
	particles:    Particle_Queue, // this step's particle bursts, for presentation
	stamps:       Stamp_Queue,    // this step's marks on the terrain
	blurs:        Blur_Queue,     // this step's new motion-blur ghosts
	effects:      Effect_Queue,   // plugins' presentation events (queue_effects.odin)
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

// Starts a session: a world for its plugins, the systems of the core and of
// the session's plugins in order, and their Setup systems run (the
// original's set-up is dr:sim/core's).
//
// The state's world is kept for the next session, put back to its start
// values, while the plugins stay the same; destroy frees it.
init :: proc(s: ^State, session: Session, defs: ^Defs, log: ^Draw_Log = nil, events: ^Event_Log = nil) {
	world, prefabs := s.ecs, s.prefabs
	s^ = State{}
	if world != nil && world.mods == session.mods {
		ecs_reset(world)
	} else {
		ecs_destroy(world)
		world = ecs_create(session.mods)
	}
	s.ecs = world
	s.session = session
	s.defs = defs
	s.events = events
	s.draws = log
	s.prefabs = prefabs
	prefabs_ensure(s)
	schedule_build(&s.schedule, session.mods)
	assert(s.schedule.system_count > 0, "sim: no systems registered -- import dr:sim/core")
	setup := Step{}
	run_systems(s, &setup, {.Setup})
}

destroy :: proc(s: ^State) {
	ecs_destroy(s.ecs)
	s.ecs = nil
	if s.prefabs != nil {
		prefabs_destroy(s.prefabs)
		free(s.prefabs)
		s.prefabs = nil
	}
}

// Appends everything a copy of s needs to buf: the state's own fields and
// its world. Pointers are written as they are and state_read replaces them,
// so a copy can go to another process.
state_write :: proc(s: ^State, buf: ^[dynamic]byte) {
	start := len(buf)
	append(buf, ..([^]u8)(s)[:size_of(State)])
	// Addresses mean nothing to the reader; send zeroes.
	fields := ([^]u8)(&buf[start])
	for off in ([?]uintptr{offset_of(State, defs), offset_of(State, ecs), offset_of(State, prefabs), offset_of(State, draws), offset_of(State, events)}) {
		runtime.mem_zero(&fields[off], size_of(rawptr))
	}
	ecs_write(s.ecs, buf)
}

// Makes s the state state_write wrote into data. s keeps its definitions,
// draw log and event log, and its world if that holds the same plugins'
// components. Fails, changing nothing, if data is not a state from this
// build.
state_read :: proc(s: ^State, data: []byte) -> bool {
	if len(data) < size_of(State) {
		return false
	}
	plain := new(State)
	defer free(plain)
	runtime.mem_copy_non_overlapping(plain, raw_data(data), size_of(State))
	world := s.ecs
	if world == nil || world.mods != plain.session.mods {
		world = ecs_create(plain.session.mods)
	}
	world_data := data[size_of(State):]
	if !ecs_readable(world, world_data) || len(world_data) != ecs_written_size(world) {
		if world != s.ecs {
			ecs_destroy(world)
		}
		return false
	}
	ecs_read(world, world_data)
	if world != s.ecs {
		ecs_destroy(s.ecs)
		s.ecs = world
	}
	restore_plain(s, plain)
	prefabs_ensure(s)
	return true
}

// s^ = plain, keeping what s points at.
@(private)
restore_plain :: proc(s: ^State, plain: ^State) {
	defs, world, prefabs, draws, events := s.defs, s.ecs, s.prefabs, s.draws, s.events
	s^ = plain^
	s.defs, s.ecs, s.prefabs, s.draws, s.events = defs, world, prefabs, draws, events
}

Level_Transition :: enum u8 {
	None,         // still playing this level
	Game_Over,    // the last player left play
	Advanced,     // this level was counted; the next one has started
	All_Complete, // the last level of the list was counted
}

// One step of a played session -- live, local or netplay -- as opposed to
// step alone, which films and the oracle tools replay. Adds what a session
// needs that FUN_00420280 does not do: the move to the next level, and the
// session plugins' own systems around the step.
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
// A plugin's system can take the whole step (Step.done): netplay's pause,
// and the screens between play (plugins/easy_mode, plugins/loadout). Only
// the frame count advances then (the rollback ring is keyed on it, and
// inputs keep flowing); game time, the RNG and every entity stand still.
// One that closes a screen freezes the rest of the step instead, so that
// the level can still move on.
session_step :: proc(s: ^State, input: Frame_Input, film: ^Film = nil) -> Level_Transition {
	st := Step{input = input, film = film}
	run_systems(s, &st, {.Step, .Session})
	return st.transition
}

// This step's presentation events start empty; step, and a plugin's system
// that takes the step, begin here.
clear_step_events :: proc "contextless" (s: ^State) {
	s.sounds.count = 0
	s.particles.count = 0
	s.stamps.count = 0
	s.blurs.count = 0
	s.effects.count = 0
	s.notices.count = 0
}

// One game step: FUN_00420280, then the game-time advance in G_Game_Play.
// `input` drives live play; with a film, players read the film instead,
// one frame per step they spend in play.
step :: proc(s: ^State, input: Frame_Input, film: ^Film = nil) {
	st := Step{input = input, film = film}
	run_systems(s, &st, {.Step})
}

step_events_system :: proc(s: ^State, step: ^Step) {
	clear_step_events(s)
}

clock_system :: proc(s: ^State, step: ^Step) {
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
