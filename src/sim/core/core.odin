package core

import "base:runtime"
import "dr:sim"
import "dr:sim/systems/weapon_system"
import "dr:sim/systems/player_system"
import "dr:sim/systems/notice_system"
import "dr:sim/systems/movement_system"
import "dr:sim/lifecycle"
import "dr:sim/systems/level_system"
import "dr:sim/systems/entity_system"
import "dr:sim/systems/debris_system"
import "dr:sim/systems/collision_system"
import "dr:sim/systems/background_system"

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

	// A session's set-up, G_Game_Play's: the seed, then both players, then
	// the first level. The world comes built, every entity with its
	// components and the session plugins' (sim/ecs.odin).
	sim.system_register({name = "session_setup", kind = .Setup, run = session_setup_system})
	sim.system_register({name = "players_setup", kind = .Setup, run = players_setup_system})
	sim.system_register({name = "level_setup", kind = .Setup, run = level_setup_system})

	// The game step, FUN_00420280, in the original's order.
	sim.system_register({name = "step_events", run = sim.step_events_system})
	sim.system_register({name = "first_player", run = level_system.first_player_system})
	sim.system_register({name = "notices", run = notice_system.notices_system})
	sim.system_register({name = "debris", run = debris_system.debris_scroll_system})
	sim.system_register({name = "players", run = player_system.players_system})
	sim.system_register({name = "game_over", run = level_system.game_over_system})
	sim.system_register({name = "background", run = background_system.background_scroll_system})
	sim.system_register({name = "level_end", run = level_system.level_end_system})
	sim.system_register({name = "entities", run = entity_system.entities_system})
	sim.system_register({name = "sweep", run = lifecycle.sweep_system})
	sim.system_register({name = "scroll_hold", run = background_system.scroll_hold_system})
	sim.system_register({name = "clock", run = sim.clock_system})
	// After the game step, in a played session.
	sim.system_register({name = "level_transition", kind = .Session, run = level_system.level_transition_system, while_frozen = true})

	// G_Player::Process for one player, in the original's order.
	sim.player_stage_register({name = "defence_bonus", run = player_system.defence_bonus_stage})
	sim.player_stage_register({name = "player_state", run = player_system.player_state_stage})
	sim.player_stage_register({name = "read_input", run = player_system.read_input_stage})
	sim.player_stage_register({name = "player_look", run = player_system.player_look_stage})
	sim.player_stage_register({name = "fire", run = player_system.fire_stage})
	sim.player_stage_register({name = "calm", run = player_system.calm_stage})
	sim.player_stage_register({name = "player_move", run = player_system.player_move_stage})

	// The components prefabs give entities, which the stages below ask for.
	sim.prefab_builder_register({name = "entity_state", build = entity_system.state_prefab})
	sim.prefab_builder_register({name = "movement", build = movement_system.movement_prefab})
	sim.prefab_builder_register({name = "collision", build = collision_system.collision_prefab})
	sim.prefab_builder_register({name = "weapon", build = weapon_system.weapon_prefab})

	// G_EG_Process's body for one entity, in the original's order. A stage
	// with a `with` set runs only on the entities that have it.
	sim.entity_stage_register({name = "appear", run = entity_system.appear_stage})
	sim.entity_stage_register({name = "state_particles", with = {entity_system.Emits_Particles}, run = entity_system.state_particles_stage})
	sim.entity_stage_register({name = "entry_sound", with = {entity_system.Entry_Sound}, run = entity_system.entry_sound_stage})
	sim.entity_stage_register({name = "state_timer", run = entity_system.state_timer_stage})
	sim.entity_stage_register({name = "scroll_pause", with = {entity_system.Pauses_Scrolling}, run = entity_system.scroll_pause_stage})
	sim.entity_stage_register({name = "animate", run = entity_system.animate_stage})
	sim.entity_stage_register({name = "rules", with = {entity_system.Follows_Rules}, run = entity_system.rules_stage})
	sim.entity_stage_register({name = "appearance", run = entity_system.appearance_stage})
	sim.entity_stage_register({name = "owner_look", with = {entity_system.Follows_Owner_Look}, run = entity_system.owner_look_stage})
	sim.entity_stage_register({name = "scroll_destruct", with = {entity_system.Destructs_While_Scrolling}, run = entity_system.scroll_destruct_stage})
	sim.entity_stage_register({name = "flee_steer", run = movement_system.flee_steer_stage})
	sim.entity_stage_register({name = "sense_players", run = movement_system.sense_players_stage})
	sim.entity_stage_register({name = "alone_delete", with = {movement_system.Deleted_Without_Players}, run = movement_system.alone_delete_stage})
	sim.entity_stage_register({name = "alone_destruct", with = {movement_system.Destructs_Without_Players}, run = movement_system.alone_destruct_stage})
	sim.entity_stage_register({name = "alone_flee", with = {movement_system.Flees_Without_Players}, run = movement_system.alone_flee_stage})
	sim.entity_stage_register({name = "cyclic_motion", with = {movement_system.Cyclic_Motion}, run = movement_system.cyclic_motion_stage})
	sim.entity_stage_register({name = "constrain", with = {movement_system.Constrained_To_Play_Area}, run = movement_system.constrain_stage})
	sim.entity_stage_register({name = "hunt", run = movement_system.hunt_stage})
	sim.entity_stage_register({name = "move", run = movement_system.move_stage})
	sim.entity_stage_register({name = "lock_to_owner", with = {movement_system.Locked_To_Owner}, run = movement_system.lock_to_owner_stage})
	sim.entity_stage_register({name = "link_to_owner", with = {movement_system.Linked_To_Owner}, run = movement_system.link_to_owner_stage})
	sim.entity_stage_register({name = "orbit_owner", with = {movement_system.Orbits_Owner}, run = movement_system.orbit_owner_stage})
	sim.entity_stage_register({name = "spawn", run = entity_system.spawn_stage})
	sim.entity_stage_register({
		name = "player_contact",
		with = {collision_system.Collides, collision_system.Collides_With_Players},
		without = {collision_system.Harmless_To_Players},
		run = collision_system.player_contact_stage,
	})
	sim.entity_stage_register({name = "motion_blur", with = {entity_system.Motion_Blur}, run = entity_system.motion_blur_stage})
	sim.entity_stage_register({
		name = "crosshair_lock",
		with = {collision_system.Ground_Based, collision_system.Hittable_By_Player_Shots, weapon_system.Targetable},
		without = {collision_system.Harmless_To_Players},
		run = weapon_system.crosshair_lock_stage,
	})
	sim.entity_stage_register({name = "ground_obstacles", with = {collision_system.Blocked_By_Wreckage}, run = collision_system.ground_obstacles_stage})
	sim.entity_stage_register({name = "shot_collisions", with = {collision_system.Collides, collision_system.Harmless_To_Players}, run = collision_system.shot_collisions_stage})
}

// srand(seed).
session_setup_system :: proc(s: ^sim.State, step: ^sim.Step) {
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
		player_system.player_setup(s, sim.player_at(s, i), i, s.session.game_type)
	}
}

level_setup_system :: proc(s: ^sim.State, step: ^sim.Step) {
	level_system.level_start(s)
}
