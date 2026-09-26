package core

import "base:runtime"
import "dr:sim"

// The original game: its systems, in the original's order. Importing this
// package is what puts the original in a build -- the simulation host
// (dr:sim) runs whatever is registered, and on its own knows no game at all.
//
// Only the order lives here, in one place, the way the original's own
// FUN_00420280 and G_Player::Process read: each system's behaviour is in
// the package that owns it. Plugins place their systems against these by
// name (sim/schedule.odin).

@(init)
register :: proc "contextless" () {
	context = runtime.default_context()

	// A session's set-up, G_Game_Play's: the session's entities and their
	// components, then (after the plugins have given them theirs) both
	// players, then the first level.
	sim.system_register({name = "session_setup", kind = .Setup, run = session_setup_system})
	sim.system_register({name = "players_setup", kind = .Setup, run = players_setup_system})
	sim.system_register({name = "level_setup", kind = .Setup, run = level_setup_system})

	// The game step, FUN_00420280, in the original's order.
	sim.system_register({name = "step_events", run = sim.step_events_system})
	sim.system_register({name = "first_player", run = sim.first_player_system})
	sim.system_register({name = "notices", run = sim.notices_system})
	sim.system_register({name = "debris", run = sim.debris_system})
	sim.system_register({name = "players", run = sim.players_system})
	sim.system_register({name = "game_over", run = sim.game_over_system})
	sim.system_register({name = "background", run = sim.background_system})
	sim.system_register({name = "level_end", run = sim.level_end_system})
	sim.system_register({name = "entities", run = sim.entities_system})
	sim.system_register({name = "sweep", run = sim.sweep_system})
	sim.system_register({name = "scroll_hold", run = sim.scroll_hold_system})
	sim.system_register({name = "clock", run = sim.clock_system})
	// After the game step, in a played session.
	sim.system_register({name = "level_transition", kind = .Session, run = sim.level_transition_system, while_frozen = true})

	// G_Player::Process for one player, in the original's order.
	sim.player_stage_register({name = "defence_bonus", run = sim.defence_bonus_stage})
	sim.player_stage_register({name = "player_state", run = sim.player_state_stage})
	sim.player_stage_register({name = "read_input", run = sim.read_input_stage})
	sim.player_stage_register({name = "player_look", run = sim.player_look_stage})
	sim.player_stage_register({name = "fire", run = sim.fire_stage})
	sim.player_stage_register({name = "calm", run = sim.calm_stage})
	sim.player_stage_register({name = "player_move", run = sim.player_move_stage})

	// G_EG_Process's body for one entity, in the original's order.
	sim.entity_stage_register({name = "appear", run = sim.appear_stage})
	sim.entity_stage_register({name = "state_particles", run = sim.state_particles_stage})
	sim.entity_stage_register({name = "entry_sound", run = sim.entry_sound_stage})
	sim.entity_stage_register({name = "state_timer", run = sim.state_timer_stage})
	sim.entity_stage_register({name = "scroll_pause", run = sim.scroll_pause_stage})
	sim.entity_stage_register({name = "animate", run = sim.animate_stage})
	sim.entity_stage_register({name = "rules", run = sim.rules_stage})
	sim.entity_stage_register({name = "appearance", run = sim.appearance_stage})
	sim.entity_stage_register({name = "owner_look", run = sim.owner_look_stage})
	sim.entity_stage_register({name = "scroll_destruct", run = sim.scroll_destruct_stage})
	sim.entity_stage_register({name = "movement_ai", run = sim.movement_ai_stage})
	sim.entity_stage_register({name = "move", run = sim.move_stage})
	sim.entity_stage_register({name = "follow_owner", run = sim.follow_owner_stage})
	sim.entity_stage_register({name = "spawn", run = sim.spawn_stage})
	sim.entity_stage_register({name = "player_contact", run = sim.player_contact_stage})
	sim.entity_stage_register({name = "motion_blur", run = sim.motion_blur_stage})
	sim.entity_stage_register({name = "crosshair_lock", run = sim.crosshair_lock_stage})
	sim.entity_stage_register({name = "ground_obstacles", run = sim.ground_obstacles_stage})
	sim.entity_stage_register({name = "shot_collisions", run = sim.shot_collisions_stage})
}

// The session's singletons, and the players' and crosshairs' components,
// zeroed; srand(seed).
session_setup_system :: proc(s: ^sim.State, step: ^sim.Step) {
	sim.add_singletons(s)
	for i in 0 ..< i32(sim.MAX_PLAYERS) {
		sim.ecs_set_components(s.ecs, sim.player_entity(i), sim.player_components())
		sim.ecs_set_components(s.ecs, sim.crosshair_entity(i), sim.crosshair_components())
	}
	sim.single(s, sim.Rng).next = s.session.seed
}

// The first level's number, and both players. An unknown level is as far
// as the port goes: nothing else is set up.
players_setup_system :: proc(s: ^sim.State, step: ^sim.Step) {
	level := sim.level_by_id(s.defs, s.session.level_id)
	if level == nil {
		sim.unported(s, 1) // unknown level id
		step.done = true
		return
	}
	sim.single(s, sim.Level_Info).number = level.number
	for i in 0 ..< i32(sim.MAX_PLAYERS) {
		sim.player_setup(s, sim.player_at(s, i), i, s.session.game_type)
	}
}

level_setup_system :: proc(s: ^sim.State, step: ^sim.Step) {
	sim.level_start(s)
}
