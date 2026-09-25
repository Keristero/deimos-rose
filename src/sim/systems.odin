package sim

import "base:runtime"

// Systems: the only code that changes the state (notes/ecs-refactor.md).
//
// A step is the registered systems run in order. Each has one job and a
// name; it is placed by naming the systems it runs after or before
// (schedule.odin), and otherwise runs in registration order, so the core's
// order is the original's. The core registers its systems in
// register_core_systems; a plugin registers its own from its own @(init).
//
// A step's entities are processed entity by entity, as G_EG_Process does:
// every stage for one entity, then every stage for the next. The stages
// are systems of their own kind (Entity_Stage), run in their own order for
// each entity. Running one stage over all entities before the next would
// change the order of the random draws, and so everything after.

MAX_SYSTEMS :: 64
MAX_STAGES :: 64

// What one step works from, and what its systems hand each other within it.
// None of it outlives the step: what the next step needs is in components.
Step :: struct {
	input:           Frame_Input,
	film:            ^Film, // when replaying a film, the players read it instead of input
	level_done:      bool,  // the background reached the top of the map this step
	pause_scrolling: bool,  // an entity's state holds the scroll this step
	// A pause or a between-play screen took the step: the game does not
	// run, though the level may still change.
	frozen:          bool,
	done:            bool, // nothing more runs this step
	transition:      Level_Transition,
}

System_Kind :: enum u8 {
	// Part of the game step (FUN_00420280): what a film or the oracle
	// replays with `step`.
	Step,
	// Around the game step, in a played session only (`session_step`).
	Session,
}

System :: struct {
	name:         string,
	after:        []string,
	before:       []string,
	kind:         System_Kind,
	run:          proc(s: ^State, step: ^Step),
	// Runs even when the step is frozen: what decides the level change.
	while_frozen: bool,
}

// One entity's pass through the stages, and what the stages hand each
// other.
Entity_Step :: struct {
	time:   i32,
	u:      ^Unit,
	// The entity's state as G_EG_Process's local holds it: refreshed where
	// the original refreshes it, which is not after every state change.
	st:     ^Unit_State,
	pause:  bool, // the state holds the scroll
	bounds: Rect, // the entity's bounds after spawning
}

// A stage returns false when the entity is done for this step (deleted,
// destroyed, or not yet appeared).
Entity_Stage :: struct {
	name:   string,
	after:  []string,
	before: []string,
	run:    proc(s: ^State, e: Entity, es: ^Entity_Step) -> bool,
}

@(private = "file")
systems: [MAX_SYSTEMS]System
@(private = "file")
system_count: int
@(private = "file")
stages: [MAX_STAGES]Entity_Stage
@(private = "file")
stage_count: int

// Called from `@(init)` procedures only, like component_register.
system_register :: proc(sys: System) {
	assert(system_count < MAX_SYSTEMS, "sim: too many systems")
	systems[system_count] = sys
	system_count += 1
}

entity_stage_register :: proc(stage: Entity_Stage) {
	assert(stage_count < MAX_STAGES, "sim: too many entity stages")
	stages[stage_count] = stage
	stage_count += 1
}

registered_systems :: proc "contextless" () -> []System {
	return systems[:system_count]
}

registered_entity_stages :: proc "contextless" () -> []Entity_Stage {
	return stages[:stage_count]
}

// The systems and stages a session runs, in order, by registry index.
// Fixed for the session, so it is the same on every peer.
Schedule :: struct {
	systems:      [MAX_SYSTEMS]u8,
	system_count: u8,
	stages:       [MAX_STAGES]u8,
	stage_count:  u8,
}

// Orders the registered systems and stages. A cycle is a bug in whoever
// registered them, found the first time any session starts.
schedule_build :: proc(sched: ^Schedule) {
	items := make([]Order_Item, max(system_count, stage_count), context.temp_allocator)
	for sys, i in systems[:system_count] {
		items[i] = {sys.name, sys.after, sys.before}
	}
	order, ok := schedule(items[:system_count], context.temp_allocator)
	assert(ok, "sim: the systems' order has a cycle")
	for idx, i in order {
		sched.systems[i] = u8(idx)
	}
	sched.system_count = u8(system_count)
	for st, i in stages[:stage_count] {
		items[i] = {st.name, st.after, st.before}
	}
	order, ok = schedule(items[:stage_count], context.temp_allocator)
	assert(ok, "sim: the entity stages' order has a cycle")
	for idx, i in order {
		sched.stages[i] = u8(idx)
	}
	sched.stage_count = u8(stage_count)
}

// Runs the session's systems of the given kinds, in order.
run_systems :: proc(s: ^State, step: ^Step, kinds: bit_set[System_Kind]) {
	for idx in s.schedule.systems[:s.schedule.system_count] {
		sys := &systems[idx]
		if sys.kind not_in kinds || (step.frozen && !sys.while_frozen) {
			continue
		}
		sys.run(s, step)
		if step.done {
			return
		}
	}
}

// Runs the session's entity stages on one entity, in order, until one
// says the entity is done.
run_entity_stages :: proc(s: ^State, e: Entity, es: ^Entity_Step) {
	for idx in s.schedule.stages[:s.schedule.stage_count] {
		if !stages[idx].run(s, e, es) {
			return
		}
	}
}

@(init)
register_core_systems :: proc "contextless" () {
	context = runtime.default_context()
	// Around the game step, in a played session.
	system_register({name = "netplay_pause", kind = .Session, run = netplay_pause_system})
	system_register({name = "reward_screen", kind = .Session, run = reward_screen_system})
	system_register({name = "loadout_screen", kind = .Session, run = loadout_screen_system})
	// The game step, FUN_00420280, in the original's order.
	system_register({name = "step_events", run = step_events_system})
	system_register({name = "first_player", run = first_player_system})
	system_register({name = "notices", run = notices_system})
	system_register({name = "debris", run = debris_system})
	system_register({name = "players", run = players_system})
	system_register({name = "game_over", run = game_over_system})
	system_register({name = "background", run = background_system})
	system_register({name = "level_end", run = level_end_system})
	system_register({name = "entities", run = entities_system})
	system_register({name = "sweep", run = sweep_system})
	system_register({name = "scroll_hold", run = scroll_hold_system})
	system_register({name = "clock", run = clock_system})
	// After the game step, in a played session.
	system_register({name = "reward_open", kind = .Session, run = reward_open_system})
	system_register({name = "loadout_open", kind = .Session, run = loadout_open_system})
	system_register({name = "level_transition", kind = .Session, run = level_transition_system, while_frozen = true})

	// G_EG_Process's body for one entity, in the original's order.
	entity_stage_register({name = "appear", run = appear_stage})
	entity_stage_register({name = "state_particles", run = state_particles_stage})
	entity_stage_register({name = "entry_sound", run = entry_sound_stage})
	entity_stage_register({name = "state_timer", run = state_timer_stage})
	entity_stage_register({name = "scroll_pause", run = scroll_pause_stage})
	entity_stage_register({name = "animate", run = animate_stage})
	entity_stage_register({name = "rules", run = rules_stage})
	entity_stage_register({name = "appearance", run = appearance_stage})
	entity_stage_register({name = "owner_look", run = owner_look_stage})
	entity_stage_register({name = "scroll_destruct", run = scroll_destruct_stage})
	entity_stage_register({name = "movement_ai", run = movement_ai_stage})
	entity_stage_register({name = "move", run = move_stage})
	entity_stage_register({name = "follow_owner", run = follow_owner_stage})
	entity_stage_register({name = "spawn", run = spawn_stage})
	entity_stage_register({name = "player_contact", run = player_contact_stage})
	entity_stage_register({name = "motion_blur", run = motion_blur_stage})
	entity_stage_register({name = "crosshair_lock", run = crosshair_lock_stage})
	entity_stage_register({name = "ground_obstacles", run = ground_obstacles_stage})
	entity_stage_register({name = "shot_collisions", run = shot_collisions_stage})
}
