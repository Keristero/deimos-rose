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

// A stage returns false when the player is done for this step.
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
	state:   i32,
	// The entity's components, its unit's and those of `st`: what a stage's
	// query is matched against.
	mask:    Component_Mask,
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
// entity has every component in `with` and none in `without` (mask_of),
// its own or shared from its prefabs (prefabs.odin).
Entity_Stage :: struct {
	name:    string,
	after:   []string,
	before:  []string,
	plugin:  Plugin_ID,
	with:    Component_Mask,
	without: Component_Mask,
	run:     proc(s: ^State, e: Entity, es: ^Entity_Step) -> bool,
}

@(private = "file")
systems: [MAX_SYSTEMS]System
@(private = "file")
system_count: int
@(private = "file")
player_stages: [MAX_STAGES]Player_Stage
@(private = "file")
player_stage_count: int
@(private = "file")
stages: [MAX_STAGES]Entity_Stage
@(private = "file")
stage_count: int

// Called from `@(init)` procedures only, like component_register. The
// `after` and `before` lists are kept, not copied, so they must outlive the
// call: package variables, not slice literals, which live on the caller's
// stack.
system_register :: proc(sys: System) {
	assert(system_count < MAX_SYSTEMS, "sim: too many systems")
	systems[system_count] = sys
	system_count += 1
}

player_stage_register :: proc(stage: Player_Stage) {
	assert(player_stage_count < MAX_STAGES, "sim: too many player stages")
	player_stages[player_stage_count] = stage
	player_stage_count += 1
}

entity_stage_register :: proc(stage: Entity_Stage) {
	assert(stage_count < MAX_STAGES, "sim: too many entity stages")
	stages[stage_count] = stage
	stage_count += 1
}

registered_systems :: proc "contextless" () -> []System {
	return systems[:system_count]
}

registered_player_stages :: proc "contextless" () -> []Player_Stage {
	return player_stages[:player_stage_count]
}

registered_entity_stages :: proc "contextless" () -> []Entity_Stage {
	return stages[:stage_count]
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
	sched.system_count = order_registered(systems[:system_count], mods, sched.systems[:])
	sched.player_stage_count = order_registered(player_stages[:player_stage_count], mods, sched.player_stages[:])
	sched.stage_count = order_registered(stages[:stage_count], mods, sched.stages[:])
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

// Runs the session's player stages on one player, in order, until one says
// the player is done.
run_player_stages :: proc(s: ^State, p: Player, ps: ^Player_Step) {
	for idx in s.schedule.player_stages[:s.schedule.player_stage_count] {
		if !player_stages[idx].run(s, p, ps) {
			return
		}
	}
}

// Runs the session's entity stages on one entity, in order, until one
// says the entity is done. A stage whose query the entity does not match
// is passed over; the entity's components are matched as they are when the
// stage comes up, since an earlier stage may have changed its state.
run_entity_stages :: proc(s: ^State, e: Entity, es: ^Entity_Step) {
	for idx in s.schedule.stages[:s.schedule.stage_count] {
		stage := &stages[idx]
		if stage.with - es.mask != {} || stage.without & es.mask != {} {
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
// local: the state, and so the components the later stages see.
entity_step_state :: proc(s: ^State, e: Entity, es: ^Entity_Step) {
	es.st = state_of(s, e)
	es.state = e.state
	es.mask = components_of(s.ecs, pool_entity(e.pool_index)) + s.prefabs.unit_mask[e.unit] + prefab_state_mask(s.prefabs, e.unit, e.state)
}

// T for the entity as the stage sees it: its own, else its state's (the
// state `es` holds), else its unit's. nil when none of them has one, and
// for a tag, which has nothing to point at (entity_has).
step_component :: proc(s: ^State, e: Entity, es: ^Entity_Step, $T: typeid) -> ^T {
	if c := get(s.ecs, pool_entity(e.pool_index), T); c != nil {
		return c
	}
	if c := get(s.prefabs.world, prefab_state_id(s.prefabs, e.unit, es.state), T); c != nil {
		return c
	}
	return get(s.prefabs.world, prefab_unit_id(e.unit), T)
}

// Whether the entity as the stage sees it has T: what a tag is asked with.
step_has :: #force_inline proc "contextless" (es: ^Entity_Step, $T: typeid) -> bool {
	return component_id(T) in es.mask
}

// Whether the entity as it is now has T, its own or shared: what a tag
// (a component with no fields, so nothing to get) is asked with.
entity_has :: proc(s: ^State, e: Entity, $T: typeid) -> bool {
	return has(s.ecs, pool_entity(e.pool_index), T) ||
		has(s.prefabs.world, prefab_state_id(s.prefabs, e.unit, e.state), T) ||
		has(s.prefabs.world, prefab_unit_id(e.unit), T)
}

// T for the entity as it is now: its own, else its current state's, else
// its unit's.
entity_component :: proc(s: ^State, e: Entity, $T: typeid) -> ^T {
	if c := get(s.ecs, pool_entity(e.pool_index), T); c != nil {
		return c
	}
	if c := get(s.prefabs.world, prefab_state_id(s.prefabs, e.unit, e.state), T); c != nil {
		return c
	}
	return get(s.prefabs.world, prefab_unit_id(e.unit), T)
}
