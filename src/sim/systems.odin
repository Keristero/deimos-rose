package sim

// Systems: the only code that changes the state (notes/ecs-refactor.md).
//
// A step is the registered systems run in order. Each has one job and a
// name; it is placed by naming the systems it runs after or before
// (schedule.odin), and otherwise runs in registration order. The original
// game registers its systems, in the original's order, from dr:sim/core; a
// plugin registers its own from its own @(init).
//
// A step's players and entities are processed one at a time, as
// G_Player::Process and G_EG_Process do: every stage for one, then every
// stage for the next. The stages are systems of their own kinds
// (Player_Stage, Entity_Stage), run in their own order for each player or
// entity. Running one stage over all of them before the next would change
// the order of the random draws, and so everything after.

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
	// Once, as a session starts: the original's set-up (dr:sim/core), and
	// where a plugin gives the session's entities its components, between
	// the core's session_setup and players_setup.
	Setup,
}

System :: struct {
	name:         string,
	after:        []string,
	before:       []string,
	plugin:       Plugin_ID, // runs only in a session with this plugin on
	kind:         System_Kind,
	run:          proc(s: ^State, step: ^Step),
	// Runs even when the step is frozen: what decides the level change.
	while_frozen: bool,
}

// One player's pass through the stages.
Player_Step :: struct {
	time:  i32,
	input: Buttons,
	film:  ^Film,
}

// A stage returns false when the player is done for this step. Every player
// has the same components (ecs.odin), so a stage runs for them all.
Player_Stage :: struct {
	name:   string,
	after:  []string,
	before: []string,
	plugin: Plugin_ID,
	run:    proc(s: ^State, p: Player, ps: ^Player_Step) -> bool,
}

// One entity's pass through the stages, and what the stages hand each
// other.
Entity_Step :: struct {
	time:    i32,
	u:       ^Unit,
	// The entity's state as G_EG_Process's local holds it: refreshed where
	// the original refreshes it, which is not after every state change
	// (entity_step_state).
	st:      ^Unit_State,
	// The prefab of `st`, which the stages' queries are matched against and
	// the components they read come from (prefabs.odin).
	prefab:  i32,
	pause:   bool, // the state holds the scroll
	// The nearest player in play, as the movement AI found it before the
	// entity moved: the stages after it act on the same sighting.
	nearest: Sighting,
	bounds:  Rect, // the entity's bounds after spawning
}

Sighting :: struct {
	loc:    Vec,
	dist:   f32,
	player: i32, // -1 for none
	found:  bool,
}

// A stage returns false when the entity is done for this step (deleted,
// destroyed, or not yet appeared). It runs for an entity only when the
// entity's prefab has every component in `with` and none in `without`
// (prefabs.odin).
Entity_Stage :: struct {
	name:    string,
	after:   []string,
	before:  []string,
	plugin:  Plugin_ID,
	with:    []typeid,
	without: []typeid,
	run:     proc(s: ^State, e: Entity, es: ^Entity_Step) -> bool,
	query:   Prefab_Query, // set by entity_stage_register
}

@(private = "file")
systems: Registry(System, MAX_SYSTEMS)
@(private = "file")
player_stages: Registry(Player_Stage, MAX_STAGES)
@(private = "file")
stages: Registry(Entity_Stage, MAX_STAGES)

// Called from `@(init)` procedures only, like component_register. The
// `after` and `before` lists are kept, not copied, so they must outlive the
// call: package variables, not slice literals, which live on the caller's
// stack.
system_register :: proc(sys: System) {
	registry_add(&systems, sys)
}

player_stage_register :: proc(stage: Player_Stage) {
	registry_add(&player_stages, stage)
}

// The stage's `with` and `without` are copied (prefab_query_register), so
// they may be slice literals.
entity_stage_register :: proc(stage: Entity_Stage) {
	kept := stage
	kept.query = prefab_query_register(stage.with, stage.without)
	kept.with, kept.without = nil, nil
	registry_add(&stages, kept)
}

registered_systems :: proc "contextless" () -> []System {
	return registry_items(&systems)
}

registered_player_stages :: proc "contextless" () -> []Player_Stage {
	return registry_items(&player_stages)
}

registered_entity_stages :: proc "contextless" () -> []Entity_Stage {
	return registry_items(&stages)
}

// The systems and stages a session runs, in order, by registry index.
// Fixed for the session, so it is the same on every peer.
Schedule :: struct {
	systems:            [MAX_SYSTEMS]u8,
	system_count:       u8,
	player_stages:      [MAX_STAGES]u8,
	player_stage_count: u8,
	stages:             [MAX_STAGES]u8,
	stage_count:        u8,
}

// Orders the registered systems and stages of the core and the plugins in
// `mods`. A cycle is a bug in whoever registered them, found the first time
// a session with them starts.
schedule_build :: proc(sched: ^Schedule, mods: Mods) {
	sched.system_count = order_registered(registry_items(&systems), mods, sched.systems[:])
	sched.player_stage_count = order_registered(registry_items(&player_stages), mods, sched.player_stages[:])
	sched.stage_count = order_registered(registry_items(&stages), mods, sched.stages[:])
}

// Orders the items of `registered` that belong to the core or a plugin in
// `mods`, as registry indexes. Placing against a plugin's item that is not
// there places against nothing.
order_registered :: proc(registered: []$T, mods: Mods, out: []u8) -> u8 {
	items := make([dynamic]Order_Item, 0, len(registered), context.temp_allocator)
	index := make([dynamic]u8, 0, len(registered), context.temp_allocator)
	for r, i in registered {
		if r.plugin == CORE || int(r.plugin) in mods {
			append(&items, Order_Item{r.name, r.after, r.before})
			append(&index, u8(i))
		}
	}
	order, ok := schedule(items[:], context.temp_allocator)
	assert(ok, "sim: a cycle in the order of the registered systems")
	for idx, i in order {
		out[i] = index[idx]
	}
	return u8(len(order))
}

// Runs the session's systems of the given kinds, in order.
run_systems :: proc(s: ^State, step: ^Step, kinds: bit_set[System_Kind]) {
	for idx in s.schedule.systems[:s.schedule.system_count] {
		sys := &systems.items[idx]
		if sys.kind not_in kinds || (step.frozen && !sys.while_frozen) {
			continue
		}
		sys.run(s, step)
		if step.done {
			return
		}
	}
}

// Runs the session's player stages on one player, in order, until one says
// the player is done.
run_player_stages :: proc(s: ^State, p: Player, ps: ^Player_Step) {
	for idx in s.schedule.player_stages[:s.schedule.player_stage_count] {
		if !player_stages.items[idx].run(s, p, ps) {
			return
		}
	}
}

// Runs the session's entity stages on one entity, in order, until one
// says the entity is done. A stage whose query the entity's prefab does not
// match is passed over; the prefab is the one `es` holds when the stage
// comes up, since an earlier stage may have refreshed it.
run_entity_stages :: proc(s: ^State, e: Entity, es: ^Entity_Step) {
	for idx in s.schedule.stages[:s.schedule.stage_count] {
		stage := &stages.items[idx]
		if !prefab_is(s, es.prefab, stage.query) {
			continue
		}
		if !stage.run(s, e, es) {
			return
		}
	}
}

// Starts an entity's pass through the stages.
entity_step :: proc(s: ^State, e: Entity, time: i32) -> Entity_Step {
	es := Entity_Step{time = time, u = unit_of(s, e)}
	entity_step_state(s, e, &es)
	return es
}

// Takes the entity's state as it is now, where G_EG_Process refreshes its
// local: the state, and so the prefab the later stages see.
entity_step_state :: proc(s: ^State, e: Entity, es: ^Entity_Step) {
	es.st = state_of(s, e)
	es.prefab = prefab_of(s, e)
}
