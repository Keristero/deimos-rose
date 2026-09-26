package sim

// The core's components (D39): plain data, as notes/ecs-refactor.md asks.
// Everything a step reads from one step to the next is one of these, on one
// of the fixed entities (ecs.odin). What acts on them is the systems under
// sim/systems/, and the entity lifecycle in sim/lifecycle/.
//
// This file holds the session entity's: the singletons, one of each for the
// whole session. Their fields are the original's globals, grouped by what
// uses them. The players' are in components_player.odin, and the entity
// pool's and the groups' in components_entity.odin.

import "base:runtime"

// Game time and session time.
Clock :: struct {
	time:  i32, // DAT_004e4836: game steps this level
	frame: u32, // steps taken this session
}

// The simulation's one random number generator (rand.odin).
Rng :: struct {
	next: u32,
}

// G_Film's per-player read positions.
Film_Cursor :: struct {
	reads: [MAX_PLAYERS]i32,
}

// Which level is being played.
Level_Info :: struct {
	number: i32,  // DAT_004e482e
	played: i32,  // DAT_004e482a: levels started this session
	ending: bool, // DAT_004e4855
	// Not the original's, which never looks back at it: the level's title
	// notice, for what waits for it to go (plugins/loadout).
	title:  Entity_Ref,
}

// G_Game_GroundAccuracy: the share of ground targets destroyed.
Accuracy :: struct {
	targets:           i32,  // DAT_004e4856
	destroyed:         i32,  // DAT_004e485a
	reward_this_level: bool, // DAT_004e4828
	perfect_level:     bool, // DAT_004e4827: this level ended at 100%
}

// Whether anyone is still playing.
Game_Status :: struct {
	player1_seen_playing: bool, // FUN_00420280's first argument
	game_over:            bool, // DAT_004e4826: no player left in the game
	// FUN_00420280's third argument: the game-over banner has been spawned.
	game_over_notice:     bool,
}

@(init)
register_core_components :: proc "contextless" () {
	context = runtime.default_context()
	// Singletons, on the session entity only.
	component_register(Clock, 1)
	component_register(Rng, 1)
	component_register(Film_Cursor, 1)
	component_register(Level_Info, 1)
	component_register(Accuracy, 1)
	component_register(Game_Status, 1)
	component_register(Bgnd, 1)
	component_register(Debris, 1)
	component_register(Notice_State, 1)
	component_register(Level_End, 1)
	component_register(Pool, 1)
	// Every object: the players, their crosshairs and the entity pool.
	component_register(Game_Object, MAX_ENTITIES)
	// The players.
	component_register(Ship, MAX_PLAYERS)
	component_register(Purse, MAX_PLAYERS)
	component_register(Hull, MAX_PLAYERS)
	component_register(Overload, MAX_PLAYERS)
	component_register(Weapon_Handler, MAX_PLAYERS)
	component_register(Crosshair, MAX_PLAYERS)
	// The entity pool.
	component_register(Actor, MAX_ENTITIES)
	component_register(Anim, MAX_ENTITIES)
	component_register(Motion, MAX_ENTITIES)
	component_register(Owned, MAX_ENTITIES)
	component_register(Spawner, MAX_ENTITIES)
	component_register(Effects, MAX_ENTITIES)
	component_register(Shaped, MAX_ENTITIES)
	// The groups.
	component_register(Group, MAX_GROUPS)
	// List membership, for pool entities and groups alike.
	component_register(Link, max(MAX_GROUPS, MAX_ENTITIES))
}

// Gives the session entity its singletons, zeroed.
add_singletons :: proc(s: ^State) {
	ecs_set_components(s.ecs, SESSION_ENTITY, {
		component_id(Clock),
		component_id(Rng),
		component_id(Film_Cursor),
		component_id(Level_Info),
		component_id(Accuracy),
		component_id(Game_Status),
		component_id(Bgnd),
		component_id(Debris),
		component_id(Notice_State),
		component_id(Level_End),
		component_id(Pool),
	})
}

// The session's T.
single :: #force_inline proc "contextless" (s: ^State, $T: typeid) -> ^T {
	return get(s.ecs, SESSION_ENTITY, T)
}

// Steps taken this session: what rollback and netplay count frames by.
frame_of :: #force_inline proc "contextless" (s: ^State) -> u32 {
	return single(s, Clock).frame
}

level_number_of :: #force_inline proc "contextless" (s: ^State) -> i32 {
	return single(s, Level_Info).number
}

// The level being played, from the definitions. nil before the first
// session starts: the menus draw from a zeroed state, which has no world yet.
level_def :: proc "contextless" (s: ^State) -> ^Level_Def {
	if s.ecs == nil {
		return nil
	}
	n := single(s, Level_Info).number
	for &l in s.defs.levels {
		if l.number == n {
			return &l
		}
	}
	return nil
}

Bgnd :: struct {
	view_top:    i32,  // DAT_004de6f4 (also G_Bgnd_GetUpdateRectTop)
	view_bottom: i32,  // DAT_004de6fc
	map_bottom:  i32,  // DAT_004de6ec: the level's background rect bottom
	progress:    i32,  // DAT_004de704: rows revealed so far
	speed:       i32,  // DAT_004de708: rows per step, 0 while paused
	finished:    bool, // DAT_004de70c: reached the top of the map
	scrolled:    i32,  // DAT_004de71e: rows scrolled this step
	// DAT_004de70d: how far the view has slid sideways, -32..31, and
	// DAT_004de711, which way it moved this step. Only drawing reads them,
	// but a player's input moves them, so they belong to the state.
	side_scroll:     i32,
	side_scroll_dir: i32,
}

// Visible play area (perm floats 0x36, 0x37).
view_width :: proc "contextless" (d: ^Defs) -> i32 {
	return trunc_i32(d.perm_floats[PF_VISIBLE_GAME_WIDTH])
}

view_height :: proc "contextless" (d: ^Defs) -> i32 {
	return trunc_i32(d.perm_floats[PF_VISIBLE_GAME_HEIGHT])
}

// G_Debris: rectangles of wreckage left on the ground. They block ground
// units that collide with obstacles, and scroll with the background.
//
// The original keeps them in an unbounded list that is only cleared at level
// start; here the pool is fixed and further debris is dropped, which can only
// differ from the original in a level that leaves more than MAX_DEBRIS
// obstacles.
MAX_DEBRIS :: 512

Debris :: struct {
	rects: [MAX_DEBRIS]Rect,
	count: i32,
}

Level_End :: struct {
	started:       bool, // DAT_004e4847
	started_time:  i32,  // DAT_004e4848
	all_done:      bool, // DAT_004e4829: this was the last level of the list
	state:         i32,  // DAT_004e4862: 0 idle, 1..10
	state_time:    i32,  // DAT_004e4866
	count_time:    i32,  // DAT_004e486e
	percent:       i32,  // DAT_004e497a: ground targets destroyed
	bonus:         i32,  // DAT_004e4872: what is left to award
	bonus_step:    i32,  // DAT_004e4876
	bonus_total:   i32,  // the bonus as first worked out: 0 reads "None!", not a count
	fade:          i32,  // DAT_004e486a
	perfect_levels: i32, // DAT_004e485e: levels finished at 100%
	perfect:       bool, // DAT_004e497e: the perfect-game bonus is running
	perfect_count: i32,  // DAT_004e4980
	complete:      bool, // DAT_004e4825: the level is over and counted
}

Money_Counter :: struct {
	state:      i32, // +0xd2
	state_time: i32, // +0xd6
	count_time: i32, // +0xe2
	multiplier: i32, // +0xde
	money:      i32, // +0x1e6
	value:      i32, // +0x1ea
	step:       i32, // +0x1ee
	offset:     i32, // +0x1f2
	fade:       i32, // +0xda
}

Notice_State :: struct {
	sound:   Sound_Settings,
	delay:   i32, // frames left before the sound plays; then frames left showing
	pending: bool,
}

NOTICE_HOLD_FRAMES :: 90
