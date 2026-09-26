package sim

import "base:runtime"

// The core's components (D39). Everything a step reads from one step to the
// next is one of these, on one of the fixed entities (ecs.odin).
//
// The session entity carries the singletons: one of each, for the whole
// session. Their fields are the original's globals, grouped by what uses
// them.

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
@(private)
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

// Game steps into this level.
time_of :: #force_inline proc "contextless" (s: ^State) -> i32 {
	return single(s, Clock).time
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
