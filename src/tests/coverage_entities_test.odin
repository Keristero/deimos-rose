package tests

import "core:log"
import vmem "core:mem/virtual"
import "core:os"
import "core:testing"

import "dr:data"
import "dr:plugins/passives"
import "dr:sim"
import _ "dr:sim/core"
import "dr:sim/lifecycle"
import "dr:sim/systems/background_system"
import "dr:sim/systems/entity_system"
import "dr:sim/systems/level_system"
import "dr:sim/systems/movement_system"
import "dr:sim/systems/notice_system"

// The entities' own behaviour -- a state's rules, its spawn sets, the
// stages of G_EG_Process -- the movement AI's reactions, and the end of a
// level: paths the shipped levels and demos never take, or take only
// deep inside a long run. Each test pins how the port reads the original.
//
// The entity tests run against the committed assets tree, on stage 1 with
// its placements cleared, so the only entities are the ship's and the
// test's own. Their subjects are two test units copied from the mine, with
// three plain states "A", "B" and "C" (no rules, spawn sets or reaction to
// range, and no speed), whose definitions a test edits in memory to reach
// the path it is about. Skipped without the assets tree. The level-end
// tests need nothing but synthetic definitions.

@(private = "file")
MINE_UNIT :: sim.Res_ID{'m', 'i', 'n', 'e'}
@(private = "file")
SUBJECT :: sim.Res_ID{'t', 's', 'u', '1'}
@(private = "file")
OTHER :: sim.Res_ID{'t', 's', 'u', '2'}
@(private = "file")
STATE_NAMES :: [3]string{"A", "B", "C"}

@(private = "file")
Fx :: struct {
	arena:  vmem.Arena,
	defs:   sim.Defs,
	s:      ^sim.State,
	events: sim.Event_Log,
}

// Stage 1 once the ship is in play, with the test units added. `edit` may
// change the definitions first: before sim.init, since the prefabs that
// turn the stages on are built from them there.
@(private = "file")
fx_open :: proc(t: ^testing.T, f: ^Fx, edit: proc(d: ^sim.Defs) = nil, mods := sim.Mods{}) -> bool {
	if !os.exists("assets/data/index.json") {
		log.info("skipped: needs the extracted assets tree")
		return false
	}
	testing.expect(t, vmem.arena_init_growing(&f.arena) == nil)
	context.allocator = vmem.arena_allocator(&f.arena) // the state's world goes in the arena too
	f.defs, _ = data.assets_defs_load("assets", context.allocator)
	mi := sim.unit_index(&f.defs, MINE_UNIT)
	if !testing.expect(t, mi >= 0, "no mine in the assets") {
		return false
	}
	n := len(f.defs.units)
	units := make([]sim.Unit, n + 2)
	copy(units, f.defs.units)
	for id, k in ([2]sim.Res_ID{SUBJECT, OTHER}) {
		u := &units[n + k]
		u^ = f.defs.units[mi]
		u.id = id
		// One entity, where it was asked for, still, and counted nowhere.
		u.num_in_group_min, u.num_in_group_max = 1, 1
		u.group_delay_min, u.group_delay_max = 0, 0
		u.x_offset_min, u.x_offset_max, u.y_offset_min, u.y_offset_max = 0, 0, 0, 0
		u.initial_speed_min, u.initial_speed_max = 0, 0
		u.flees_south_on_no_active_players = false
		u.include_in_air_accuracy_count = false
		u.include_in_ground_accuracy_count = false
		names := STATE_NAMES
		states := make([]sim.Unit_State, len(names))
		for &st, j in states {
			st = f.defs.units[mi].states[0]
			st.name = names[j]
			st.rules, st.spawn_sets = nil, nil
			st.on_range, st.on_range_change_to = 0, ""
			st.hunts = false
			st.max_speed, st.delta = 0, 0
		}
		u.states = states
	}
	f.defs.units = units
	for &l in f.defs.levels {
		l.placements = nil
	}
	if edit != nil {
		edit(&f.defs)
	}
	f.events = {events = make([]sim.Event, 1 << 14)}
	f.s = new(sim.State)
	sim.init(f.s, sim.Session{seed = 1, level_id = f.defs.levels[0].id, game_type = .Single, mods = mods}, &f.defs, events = &f.events)
	for i := 0; i < 300 && sim.player_at(f.s, 0).state != .Playing; i += 1 {
		sim.session_step(f.s, {})
	}
	return testing.expect(t, sim.player_at(f.s, 0).state == .Playing, "the ship must be in play")
}

// An entity of `unit` at `loc`, appeared.
@(private = "file")
fx_spawn :: proc(t: ^testing.T, s: ^sim.State, unit: sim.Res_ID, loc: sim.Vec, owner := sim.NO_REF) -> (sim.Entity, bool) {
	req := sim.spawn_request(unit)
	req.loc = loc
	req.owner = owner
	r := lifecycle.eg_request_spawn(s, req)
	if !testing.expectf(t, sim.ref_valid(s, r), "%v must spawn", unit) {
		return {}, false
	}
	e := sim.entity_at(s, r.index)
	e.loc = loc
	e.appear_delay = 0
	return e, true
}

// The live entities of `unit` numbered `from` or later: those spawned since
// the pool's next number was `from`.
@(private = "file")
spawned_since :: proc(s: ^sim.State, unit: sim.Res_ID, from: i32) -> [dynamic]sim.Entity {
	out: [dynamic]sim.Entity
	ui := sim.unit_index(s.defs, unit)
	for used, i in sim.single(s, sim.Pool).entity_used {
		if !used {
			continue
		}
		e := sim.entity_at(s, i32(i))
		if !e.deleted && e.unit == ui && e.number >= from {
			append(&out, e)
		}
	}
	return out
}

@(private = "file")
state_index :: proc(s: ^sim.State, e: sim.Entity, name: string) -> i32 {
	i, _ := sim.state_find(sim.unit_of(s, e), name)
	return i32(i)
}

// Rules.

// G_EG_RuleCondition_IsEntityActive / IsEntityTrackingPlayer: a rule naming
// a unit holds while an appeared entity of it is within the rule's range
// (0 for anywhere, the edge included); "tracking" also needs that entity to
// be turning towards its target. No shipped rule that names a unit asks
// whether it is tracking, so the subject's rule is set here.
@(test)
rules_watch_for_entities_of_a_unit :: proc(t: ^testing.T) {
	f: Fx
	defer vmem.arena_destroy(&f.arena)
	if !fx_open(t, &f) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	me, ok1 := fx_spawn(t, s, SUBJECT, {100, 100})
	other, ok2 := fx_spawn(t, s, OTHER, {150, 100}) // 50 away
	if !ok1 || !ok2 {
		return
	}
	rules := make([]sim.Rule, 1)
	sim.unit_find(&f.defs, SUBJECT).states[0].rules = rules
	now := sim.single(s, sim.Clock).time
	Case :: struct {
		cond:     data.Rule_Condition,
		range:    i32,
		rotating: bool,
		appear:   i32,
		holds:    bool,
	}
	cases := [?]Case {
		{.Is_Tracking_Player, 100, true, 0, true},
		{.Is_Tracking_Player, 100, false, 0, false}, // not turning
		{.Is_Tracking_Player, 30, true, 0, false}, // out of range
		{.Is_Not_Tracking_Player, 100, false, 0, true},
		{.Is_Not_Tracking_Player, 0, true, 0, false},
		{.Is_Active, 0, false, 0, true},
		{.Is_Active, 50, false, 0, true}, // on the edge of the range
		{.Is_Active, 0, false, 5, false}, // not appeared yet
		{.Is_Not_Active, 0, false, 5, true},
		{.Is_Not_Active, 0, false, 0, false},
	}
	for c in cases {
		rules[0] = {unit = OTHER, range = c.range, condition = u8(c.cond), action = "B"}
		other.rotating, other.appear_delay = c.rotating, c.appear
		lifecycle.change_state(s, me, false, "A", now)
		del, des := entity_system.process_rules(s, me, now)
		testing.expect(t, !del && !des)
		testing.expectf(t, (me.state == state_index(s, me, "B")) == c.holds, "%v range %v rotating %v appear %v: holds %v", c.cond, c.range, c.rotating, c.appear, c.holds)
	}
}

// G_EG_RuleCondition_IsAnyDestroyable{Air,Ground}EntityActive: the air and
// ground accuracy flags say what counts, and a ground entity counts only
// while it is within the game area.
@(test)
rules_watch_for_destroyable_entities :: proc(t: ^testing.T) {
	f: Fx
	defer vmem.arena_destroy(&f.arena)
	if !fx_open(t, &f) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	me, ok := fx_spawn(t, s, SUBJECT, {100, 100})
	if !ok {
		return
	}
	rules := make([]sim.Rule, 1)
	sim.unit_find(&f.defs, SUBJECT).states[0].rules = rules
	now := sim.single(s, sim.Clock).time
	holds :: proc(s: ^sim.State, me: sim.Entity, rules: []sim.Rule, cond: data.Rule_Condition, now: i32) -> bool {
		// Any unit that exists will do: these conditions do not read it.
		rules[0] = {unit = SUBJECT, condition = u8(cond), action = "B"}
		lifecycle.change_state(s, me, false, "A", now)
		entity_system.process_rules(s, me, now)
		return me.state == state_index(s, me, "B")
	}
	AIR :: data.Rule_Condition.No_Destroyable_Air_Entities_Are_Active
	GROUND :: data.Rule_Condition.No_Destroyable_Ground_Entities_Are_Active
	EITHER :: data.Rule_Condition.No_Destroyable_Air_Or_Ground_Entities_Are_Active

	testing.expect(t, holds(s, me, rules, AIR, now), "nothing counts yet")
	testing.expect(t, holds(s, me, rules, GROUND, now))
	testing.expect(t, holds(s, me, rules, EITHER, now))

	other, ok2 := fx_spawn(t, s, OTHER, {200, 100})
	if !ok2 {
		return
	}
	u := sim.unit_find(&f.defs, OTHER)
	u.include_in_air_accuracy_count = true
	testing.expect(t, !holds(s, me, rules, AIR, now), "an air target is active")
	testing.expect(t, holds(s, me, rules, GROUND, now))
	testing.expect(t, !holds(s, me, rules, EITHER, now))

	u.include_in_air_accuracy_count, u.include_in_ground_accuracy_count = false, true
	testing.expect(t, holds(s, me, rules, AIR, now))
	testing.expect(t, !holds(s, me, rules, GROUND, now), "a ground target is active")
	testing.expect(t, !holds(s, me, rules, EITHER, now))
	other.loc = {-50, 100} // off the game area
	testing.expect(t, holds(s, me, rules, GROUND, now), "a ground target off the game area does not count")
	testing.expect(t, holds(s, me, rules, EITHER, now))
}

// G_Entity::Priv_CheckWithinRangeOfPlayers: within means closer than the
// rule's range (strictly) to the nearest player in play; a range of 0 is
// never within.
@(test)
rules_measure_the_range_to_the_nearest_player :: proc(t: ^testing.T) {
	f: Fx
	defer vmem.arena_destroy(&f.arena)
	if !fx_open(t, &f) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	sim.player_at(s, 0).loc = {208, 330} // whole, so the distance below is exact
	me, ok := fx_spawn(t, s, SUBJECT, {208, 230})
	if !ok {
		return
	}
	rules := make([]sim.Rule, 1)
	sim.unit_find(&f.defs, SUBJECT).states[0].rules = rules
	now := sim.single(s, sim.Clock).time
	Case :: struct {
		cond:  data.Rule_Condition,
		range: i32,
		holds: bool,
	}
	cases := [?]Case {
		{.Within_Range_Of_A_Player, 150, true},
		{.Within_Range_Of_A_Player, 100, false}, // exactly 100 away
		{.Within_Range_Of_A_Player, 0, false},
		{.Not_Within_Range_Of_A_Player, 150, false},
		{.Not_Within_Range_Of_A_Player, 100, true},
		{.Not_Within_Range_Of_A_Player, 0, true},
	}
	for c in cases {
		rules[0] = {unit = SUBJECT, range = c.range, condition = u8(c.cond), action = "B"}
		lifecycle.change_state(s, me, false, "A", now)
		entity_system.process_rules(s, me, now)
		testing.expectf(t, (me.state == state_index(s, me, "B")) == c.holds, "%v range %v: holds %v", c.cond, c.range, c.holds)
	}
}

// The conditions on the entity's own look -- visibility, tint and scale at
// the state's targets -- and on how many of a unit have appeared; and the
// first rule that holds is the one acted on.
@(test)
rules_compare_the_entitys_look_and_the_count_of_a_unit :: proc(t: ^testing.T) {
	f: Fx
	defer vmem.arena_destroy(&f.arena)
	if !fx_open(t, &f) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	me, ok1 := fx_spawn(t, s, SUBJECT, {100, 100})
	_, ok2 := fx_spawn(t, s, OTHER, {200, 100})
	if !ok1 || !ok2 {
		return
	}
	rules := make([]sim.Rule, 2)
	sim.unit_find(&f.defs, SUBJECT).states[0].rules = rules
	now := sim.single(s, sim.Clock).time
	B, C := state_index(s, me, "B"), state_index(s, me, "C")
	run :: proc(s: ^sim.State, me: sim.Entity, now: i32, set: proc(e: sim.Entity)) -> i32 {
		lifecycle.change_state(s, me, false, "A", now)
		me.visibility, me.visibility_target = 50, 100
		me.tint, me.tint_target = 0, 40
		me.scale, me.scale_target = 1, 2
		set(me)
		entity_system.process_rules(s, me, now)
		return me.state
	}
	nothing :: proc(e: sim.Entity) {}

	rules[1] = {}
	rules[0] = {unit = SUBJECT, condition = u8(data.Rule_Condition.Visibility_Is_At_Required_Level), action = "B"}
	testing.expect_value(t, run(s, me, now, nothing), i32(0))
	testing.expect_value(t, run(s, me, now, proc(e: sim.Entity) {e.visibility = 100}), B)
	rules[0].condition = u8(data.Rule_Condition.Tint_Is_At_Required_Level)
	testing.expect_value(t, run(s, me, now, nothing), i32(0))
	testing.expect_value(t, run(s, me, now, proc(e: sim.Entity) {e.tint = 40}), B)
	rules[0].condition = u8(data.Rule_Condition.Scale_Is_At_Required_Level)
	testing.expect_value(t, run(s, me, now, nothing), i32(0))
	testing.expect_value(t, run(s, me, now, proc(e: sim.Entity) {e.scale = 2}), B)

	// One OTHER has appeared: more than 0 of them, not more than 1.
	rules[0] = {unit = OTHER, range = 0, condition = u8(data.Rule_Condition.Are_More_Of_These_Entities_Active), action = "B"}
	testing.expect_value(t, run(s, me, now, nothing), B)
	rules[0].range = 1
	testing.expect_value(t, run(s, me, now, nothing), i32(0))

	// Two rules: the second is acted on only when the first does not hold.
	rules[0] = {unit = SUBJECT, condition = u8(data.Rule_Condition.Tint_Is_At_Required_Level), action = "C"}
	rules[1] = {unit = SUBJECT, condition = u8(data.Rule_Condition.Visibility_Is_At_Required_Level), action = "B"}
	testing.expect_value(t, run(s, me, now, proc(e: sim.Entity) {e.visibility = 100}), B)
	testing.expect_value(t, run(s, me, now, proc(e: sim.Entity) {e.visibility, e.tint = 100, 40}), C)
}

// Spawn sets.

// G_Entity::Priv_DoRotationAsRequired: an entity that turns to its target
// holds still while a volley of a set that pauses rotation is under way
// (some of it spawned, not all), and for the pause SpawnControl sets when
// such a set starts a new volley, counted down a step at a time.
@(test)
rotation_pauses_while_a_volley_spawns :: proc(t: ^testing.T) {
	f: Fx
	defer vmem.arena_destroy(&f.arena)
	if !fx_open(t, &f, proc(d: ^sim.Defs) {
		st := &sim.unit_find(d, SUBJECT).states[0]
		st.do_rotate_to_target = true
		sets := make([]sim.Spawn_Set_Def, 1)
		sets[0] = {
			spawn                                 = OTHER,
			repeat_spawns                         = true,
			rate_min                              = 10,
			rate_max                              = 10,
			num_in_volley_min                     = 3,
			num_in_volley_max                     = 3,
			delay_between_entities_min            = 1,
			delay_between_entities_max            = 1,
			pause_any_rotation_while_spawning     = true,
			time_to_pause_rotation_after_spawning = 4,
		}
		st.spawn_sets = sets
	}) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	me, ok := fx_spawn(t, s, SUBJECT, {100, 100})
	if !ok {
		return
	}
	now := sim.single(s, sim.Clock).time
	me.hunt_player, me.hunt_target = 0, sim.player_at(s, 0).loc
	info := &me.spawn_info[0]

	// The state's first volley starts with the pause already set.
	testing.expect_value(t, me.spawn_pause, i32(4))
	testing.expect(t, !movement_system.rotate_as_required(s, me, now))
	testing.expect_value(t, me.spawn_pause, i32(3))
	testing.expect(t, !me.rotating, "a paused entity does not turn")

	// Mid-volley.
	me.spawn_pause = 0
	info.left, info.volley = 2, 3
	testing.expect(t, !movement_system.rotate_as_required(s, me, now))
	testing.expect(t, !me.rotating, "an entity does not turn mid-volley")

	// A volley not yet begun does not hold it.
	info.left = 3
	movement_system.rotate_as_required(s, me, now)
	testing.expect(t, me.rotating, "between volleys the entity turns")

	// The volley done and its delay run out: a new one is drawn, which
	// sets the pause again.
	info.left, info.last, info.delay = 0, now - 10, 10
	entity_system.spawn_control(s, me, now)
	testing.expect_value(t, info.left, i32(3))
	testing.expect_value(t, info.volley, i32(3))
	testing.expect_value(t, info.last, now)
	testing.expect_value(t, me.spawn_pause, i32(4))
	me.rotating = false
	testing.expect(t, !movement_system.rotate_as_required(s, me, now + 1))
	testing.expect(t, !me.rotating)
}

// A child whose unit sets adjustInitialLocForOwnerScale is placed at its
// spawn set's offset scaled by its parent's scale -- rotated with the
// parent's facing too, when the set says so; without the flag the offset is
// taken as it is.
@(test)
spawn_offsets_scale_with_the_parent :: proc(t: ^testing.T) {
	f: Fx
	defer vmem.arena_destroy(&f.arena)
	if !fx_open(t, &f) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	me, ok := fx_spawn(t, s, SUBJECT, {150, 150})
	if !ok {
		return
	}
	me.scale = 2
	me.frame = 0 // facing 0 degrees: the mine's 36 frames are 10 degrees apart
	child := sim.unit_find(&f.defs, OTHER)
	child.adjust_initial_loc_for_owner_scale = true
	placed :: proc(t: ^testing.T, s: ^sim.State, me: sim.Entity, set: sim.Spawn_Set_Def) -> sim.Vec {
		set := set
		from := sim.single(s, sim.Pool).next_entity
		entity_system.spawn_child_set(s, me, &set)
		got := spawned_since(s, OTHER, from)
		if !testing.expect_value(t, len(got), 1) {
			return {}
		}
		return got[0].loc - me.loc
	}
	set := sim.Spawn_Set_Def{spawn = OTHER, x_offset = 10, y_offset = -20}
	testing.expect_value(t, placed(t, s, me, set), sim.Vec{20, -40})
	set.adjust_offset_for_unit_rotation = true
	testing.expect_value(t, placed(t, s, me, set), sim.Vec{20, -40})
	// Facing 90 degrees: the scaled offset turned a quarter.
	me.frame = 9
	c, sn := sim.m_cos(90), sim.m_sin(90)
	want := sim.Vec{f32(sim.trunc_i32(20 * c + 40 * sn)), f32(sim.trunc_i32(20 * sn - 40 * c))}
	got := placed(t, s, me, set)
	testing.expect_value(t, got, want)
	testing.expect(t, abs(got.x - 40) <= 1 && abs(got.y - 20) <= 1, "a quarter turn takes (20, -40) to about (40, 20)")

	child.adjust_initial_loc_for_owner_scale = false
	me.frame = 0
	set.adjust_offset_for_unit_rotation = false
	testing.expect_value(t, placed(t, s, me, set), sim.Vec{10, -20})
	set.adjust_offset_for_unit_rotation = true
	testing.expect_value(t, placed(t, s, me, set), sim.Vec{10, -20})
}

// A spawner whose volleys its weapon's stats have sped up runs its spawn
// sets on their own clock: at a pace of 150 it runs them one step, then
// two, then one... and stops the moment it is deleted.
@(test)
a_paced_spawner_runs_its_spawn_sets_on_its_own_clock :: proc(t: ^testing.T) {
	f: Fx
	defer vmem.arena_destroy(&f.arena)
	if !fx_open(t, &f) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	me, ok := fx_spawn(t, s, SUBJECT, {100, 100})
	if !ok {
		return
	}
	// What stats.shaped_entity_init sets for a 33% shorter volley delay.
	me.spawn_pace = 150
	me.spawn_clock = 1000
	now := sim.single(s, sim.Clock).time
	runs :: proc(f: ^Fx, me: sim.Entity, time: i32) -> (n: int, carry_on: bool) {
		f.events.count = 0
		es := sim.entity_step(f.s, me, time)
		carry_on = entity_system.spawn_stage(f.s, me, &es)
		for ev in sim.event_log_entries(&f.events) {
			if ev.kind == .Spawn_Control && ev.number == me.number {
				n += 1
			}
		}
		return
	}
	want := [4]int{1, 2, 1, 2}
	for w, i in want {
		n, carry_on := runs(&f, me, now + i32(i))
		testing.expectf(t, n == w && carry_on, "step %d ran the spawn sets %d times, want %d", i, n, w)
	}
	testing.expect_value(t, me.spawn_clock, i32(1006))
	lifecycle.entity_delete(me)
	n, carry_on := runs(&f, me, now + 4)
	testing.expect_value(t, n, 0)
	testing.expect(t, !carry_on, "a deleted spawner ends its step")
}

// A spawner fired by a weapon a passive shapes (plugins/passives) shapes
// its own projectile sets: the Rear Gun's third level fires each of its
// bullet spawner's forward lanes (heading 0) out to the side as well -- left
// of the centre line to the left, 270, right of it to the right, 90 -- but
// not its backward ones (180); and an extra projectile adds a lane across
// the spread. The Rear Gun's passive has no extra
// projectiles, so the spawner is marked as the Ion Cannon's, whose first
// level has one. Its flash sets are not projectiles and spawn as they are.
@(test)
a_shaped_spawner_fires_extra_lanes_and_to_the_sides :: proc(t: ^testing.T) {
	f: Fx
	defer vmem.arena_destroy(&f.arena)
	if !fx_open(t, &f, mods = session_mods(true, false)) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	weapon :: proc(d: ^sim.Defs, id: sim.Res_ID) -> u8 {
		for &w, i in d.weapons {
			if w.id == id {
				return u8(i + 1)
			}
		}
		return 0
	}
	rear, ion := weapon(&f.defs, passives.WEAPON_REAR_GUN), weapon(&f.defs, passives.WEAPON_ION_CANNON)
	if !testing.expect(t, rear != 0 && ion != 0, "the Rear Gun and the Ion Cannon must load") {
		return
	}
	SPAWNER :: sim.Res_ID{'r', 'g', 'b', 's'}
	BULLET :: sim.Res_ID{'r', 'g', 'b', 'u'}
	// One volley of a bullet spawner the player fired: its sets wait two
	// steps before their first bullets.
	volley :: proc(t: ^testing.T, s: ^sim.State, shaped_by: u8) -> [dynamic]sim.Entity {
		req := sim.spawn_request(SPAWNER)
		req.loc = {200, 200}
		req.owner_player = 0
		req.shaped_by = shaped_by
		r := lifecycle.eg_request_spawn(s, req)
		if !testing.expect(t, sim.ref_valid(s, r), "the bullet spawner must spawn") {
			return {}
		}
		e := sim.entity_at(s, r.index)
		from := sim.single(s, sim.Pool).next_entity
		now := sim.single(s, sim.Clock).time
		entity_system.spawn_control(s, e, now)
		entity_system.spawn_control(s, e, now + 1)
		return spawned_since(s, BULLET, from)
	}
	// How many bullets head 0, 180, 270 and 90.
	headings :: proc(bullets: []sim.Entity) -> (out: [4]int) {
		for b in bullets {
			switch b.heading {
			case 0:
				out[0] += 1
			case 180:
				out[1] += 1
			case 270:
				out[2] += 1
			case 90:
				out[3] += 1
			}
		}
		return
	}
	levels := passives.levels_of(s, 0)

	// Unshaped, or shaped with nothing to add: its four lanes, two each
	// way, one either side of the centre line.
	plain := volley(t, s, 0)
	testing.expect_value(t, headings(plain[:]), [4]int{2, 2, 0, 0})
	testing.expect_value(t, len(volley(t, s, rear)), 4)

	levels^[.Weapon_3] = 3 // side fire
	sides := volley(t, s, rear)
	testing.expect_value(t, len(sides), 6)
	testing.expect_value(t, headings(sides[:]), [4]int{2, 2, 1, 1})
	for b in sides {
		if b.heading == 270 || b.heading == 90 {
			testing.expectf(t, (b.heading == 270) == (b.loc.x < 200), "a side shot at x %v heads %v", b.loc.x, b.heading)
		}
	}
	// What it spawns is shaped one step further, so its bullets spawn
	// nothing more themselves.
	for b in sides {
		testing.expect_value(t, b.shaped_depth, u8(1))
	}

	levels^ = {}
	levels^[.Weapon_1] = 1 // one extra projectile
	testing.expect_value(t, len(volley(t, s, ion)), 5)
}

// Stages.

// stateParticlesRepeat: a burst every repeat delay, up to the state's
// most; the count goes on past it, so no more bursts come.
@(test)
state_particles_repeat_up_to_the_most_bursts :: proc(t: ^testing.T) {
	f: Fx
	defer vmem.arena_destroy(&f.arena)
	if !fx_open(t, &f, proc(d: ^sim.Defs) {
		st := &sim.unit_find(d, SUBJECT).states[0]
		st.particles = sim.res_id("tiny")
		st.particles_repeat = true
		st.particles_repeat_delay = 3
		st.particles_max_num_bursts = 2
	}) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	me, ok := fx_spawn(t, s, SUBJECT, {100, 100})
	if !ok {
		return
	}
	now := sim.single(s, sim.Clock).time
	bursts: [7]int
	for i in 0 ..< len(bursts) {
		s.particles.count = 0
		es := sim.entity_step(s, me, now + i32(i))
		entity_system.state_particles_stage(s, me, &es)
		bursts[i] = s.particles.count
	}
	testing.expect_value(t, bursts, [7]int{1, 0, 0, 1, 0, 0, 0})
	testing.expect_value(t, me.particle_count, i32(3))
	testing.expect_value(t, me.particle_time, now + 6)
}

// FUN_0041b5d0: useOwnersVisibility and useOwnersScale make an entity take
// its owner's visibility and scale, and its size from them.
@(test)
an_entity_can_follow_its_owners_look :: proc(t: ^testing.T) {
	f: Fx
	defer vmem.arena_destroy(&f.arena)
	if !fx_open(t, &f, proc(d: ^sim.Defs) {
		st := &sim.unit_find(d, OTHER).states[0]
		st.use_owners_visibility = true
		st.use_owners_scale = true
	}) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	owner, ok1 := fx_spawn(t, s, SUBJECT, {100, 100})
	if !ok1 {
		return
	}
	child, ok2 := fx_spawn(t, s, OTHER, {100, 100}, sim.Entity_Ref{owner.pool_index, owner.number})
	if !ok2 {
		return
	}
	owner.visibility = 40
	owner.scale, owner.scale_target, owner.scale_delta = 1.5, 2, 0.25
	owner.dims_dirty = true
	es := sim.entity_step(s, child, sim.single(s, sim.Clock).time)
	entity_system.owner_look_stage(s, child, &es)
	testing.expect_value(t, child.visibility, f32(40))
	testing.expect_value(t, child.scale, f32(1.5))
	testing.expect_value(t, child.scale_target, f32(2))
	testing.expect_value(t, child.scale_delta, f32(0.25))
	testing.expect_value(t, child.dims, lifecycle.sprite_dims(s, child.sprite, child.frame, 1.5))
	testing.expect(t, !child.dims_dirty)
}

// stateDestructIfVerticalScrollingNotPaused: an entity in such a state is
// destroyed on any step the background scrolls, and left alone while it
// holds. Only the state with the flag has the stage.
@(test)
a_state_can_destroy_its_entity_while_the_background_scrolls :: proc(t: ^testing.T) {
	f: Fx
	defer vmem.arena_destroy(&f.arena)
	if !fx_open(t, &f, proc(d: ^sim.Defs) {
		sim.unit_find(d, SUBJECT).states[2].destruct_if_vertical_scrolling_not_paused = true
	}) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	me, ok := fx_spawn(t, s, SUBJECT, {100, 100})
	if !ok {
		return
	}
	now := sim.single(s, sim.Clock).time
	step :: proc(s: ^sim.State, e: sim.Entity, time: i32) {
		es := sim.entity_step(s, e, time)
		sim.run_entity_stages(s, e, &es)
	}
	b := sim.single(s, sim.Bgnd)
	b.speed = 1
	step(s, me, now)
	testing.expect(t, !me.deleted, "state A does not have the flag")

	lifecycle.change_state(s, me, false, "C", now)
	b.speed = 0
	step(s, me, now + 1)
	testing.expect(t, !me.deleted, "the background holds: the entity stays")
	b.speed = 1
	step(s, me, now + 2)
	testing.expect(t, me.deleted && me.destroyed, "the background scrolls: the entity is destroyed")
}

// Movement.

// G_Entity::DoMovementAI's reaction to coming within stateOnRange of the
// nearest player: Delete and Destroy end the entity; a state name changes
// its state, and a counter on the new state can end it in turn; the new
// state may head away from the target (stateReverseDirectionOnReaction) or
// close on it at its hold speed (stateHoldPositionToTarget).
@(test)
reaching_range_of_a_player_sets_off_the_reaction :: proc(t: ^testing.T) {
	f: Fx
	defer vmem.arena_destroy(&f.arena)
	if !fx_open(t, &f) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	me, ok := fx_spawn(t, s, SUBJECT, {100, 100})
	if !ok {
		return
	}
	u := sim.unit_find(&f.defs, SUBJECT)
	a, b, c := &u.states[0], &u.states[1], &u.states[2]
	a.on_range = 100
	now := sim.single(s, sim.Clock).time
	below := sim.Sighting{loc = me.loc + {0, 50}, dist = 50, player = 0, found = true}
	react :: proc(s: ^sim.State, me: sim.Entity, a: ^sim.Unit_State, to: string, n: sim.Sighting, now: i32) -> (del, des: bool) {
		lifecycle.change_state(s, me, false, "A", now)
		me.vel = {}
		a.on_range_change_to = to
		return movement_system.hunt(s, me, n, now)
	}

	del, des := react(s, me, a, "Delete", below, now)
	testing.expect(t, del && !des)
	del, des = react(s, me, a, "Destroy", below, now)
	testing.expect(t, !del && des)
	// Out of range: no reaction.
	far := below
	far.dist = 100
	del, des = react(s, me, a, "Delete", far, now)
	testing.expect(t, !del && !des)

	// Entering C runs its counter, which deletes on the first entry.
	c.on_counter, c.on_counter_change_to = 1, "Delete"
	del, des = react(s, me, a, "C", below, now)
	testing.expect(t, del && !des)
	testing.expect_value(t, me.state, i32(2))

	// B turns away from the target at its top speed.
	b.reverse_direction_on_reaction = true
	b.max_speed = 3
	del, des = react(s, me, a, "B", below, now)
	testing.expect(t, !del && !des)
	testing.expect_value(t, me.state, i32(1))
	testing.expect_value(t, me.vel_target, sim.Vec{0, -3})

	// B holds to the target instead: it closes on it.
	b.reverse_direction_on_reaction = false
	b.max_speed = 0
	b.hold_position_to_target = true
	b.hold_max_speed, b.hold_delta = 2, 0.5
	right_below := sim.Sighting{loc = me.loc + {30, 40}, dist = 50, player = 0, found = true}
	react(s, me, a, "B", right_below, now)
	testing.expect_value(t, me.state, i32(1))
	testing.expectf(t, me.vel.x > 0 && me.vel.y > 0, "holding closes on the target, velocity %v", me.vel)
}

// G_Entity::Priv_HoldToTarget: toward the target by the hold delta on each
// axis, capped at the hold speed either way.
@(test)
holding_to_a_target_is_capped_at_the_hold_speed :: proc(t: ^testing.T) {
	f: Fx
	defer vmem.arena_destroy(&f.arena)
	if !fx_open(t, &f, proc(d: ^sim.Defs) {
		st := &sim.unit_find(d, SUBJECT).states[0]
		st.hold_max_speed, st.hold_delta = 2, 0.5
	}) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	me, ok := fx_spawn(t, s, SUBJECT, {100, 100})
	if !ok {
		return
	}
	me.vel = {3, -3}
	movement_system.hold_to_target(s, me, me.loc + {30, 40})
	testing.expect_value(t, me.vel_delta, sim.Vec{0.5, 0.5})
	testing.expect_value(t, me.vel, sim.Vec{2, -2})
	me.vel = {-3, 3}
	movement_system.hold_to_target(s, me, me.loc + {-30, -40})
	testing.expect_value(t, me.vel_delta, sim.Vec{-0.5, -0.5})
	testing.expect_value(t, me.vel, sim.Vec{-2, 2})
	me.vel = {0, 0}
	movement_system.hold_to_target(s, me, me.loc + {-30, 40})
	testing.expect_value(t, me.vel, sim.Vec{-0.5, 0.5})
}

// FUN_0041bf70 and Priv_AdjustToRequiredVelocity for an orbiting entity:
// its horizontal speed is the orbit's angular speed, which approaches the
// state's top speed by its delta; the angle advances by it each step,
// wrapping either way round, and the entity sits on the circle there.
@(test)
an_orbit_wraps_its_angle_both_ways :: proc(t: ^testing.T) {
	f: Fx
	defer vmem.arena_destroy(&f.arena)
	if !fx_open(t, &f, proc(d: ^sim.Defs) {
		st := &sim.unit_find(d, SUBJECT).states[0]
		st.orbit_owner = true
		st.max_speed, st.delta = 5, 1
	}) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	owner, ok1 := fx_spawn(t, s, OTHER, {200, 200})
	if !ok1 {
		return
	}
	me, ok2 := fx_spawn(t, s, SUBJECT, {230, 200}, sim.Entity_Ref{owner.pool_index, owner.number})
	if !ok2 {
		return
	}
	me.orbit_radius = 30 // what the spawn's cache worked out, as a whole

	me.vel.x = 0
	for want in ([?]f32{1, 2, 3, 4, 5, 5}) {
		movement_system.adjust_to_required_velocity(s, me)
		testing.expect_value(t, me.vel.x, want)
	}
	me.vel.x = 7
	movement_system.adjust_to_required_velocity(s, me)
	testing.expect_value(t, me.vel.x, f32(6))
	// A delta that would overshoot stops at the top speed, from either side.
	me.vel.x = 4.5
	movement_system.adjust_to_required_velocity(s, me)
	testing.expect_value(t, me.vel.x, f32(5))
	me.vel.x = 5.5
	movement_system.adjust_to_required_velocity(s, me)
	testing.expect_value(t, me.vel.x, f32(5))

	orbit :: proc(t: ^testing.T, s: ^sim.State, me, owner: sim.Entity, from, speed, want: i32) {
		me.orbit_angle = from
		me.vel.x = f32(speed)
		movement_system.orbit_owner(s, me)
		testing.expect_value(t, me.orbit_angle, want)
		at := owner.loc + sim.vector_from_angle_and_speed(want, 30)
		testing.expect_value(t, me.loc, at)
		testing.expect_value(t, me.owner_offset, at - owner.loc)
	}
	orbit(t, s, me, owner, 3, -5, 358)
	orbit(t, s, me, owner, 358, 5, 3)
	orbit(t, s, me, owner, 100, 5, 105)
}

// Level end (synthetic definitions).

@(private = "file")
TICK :: sim.Res_ID{'t', 'i', 'c', 'k'} // perm sound 0x14: every step of the readout
@(private = "file")
NIL_BONUS :: sim.Res_ID{'n', 'i', 'l', ' '} // 0x15: no bonus to count
@(private = "file")
PERFECT_LEVEL :: sim.Res_ID{'p', 'e', 'r', 'f'} // 0x16: a level at 100%
@(private = "file")
PERFECT_GAME :: sim.Res_ID{'g', 'a', 'm', 'e'} // 0x17: every level at 100%

// Bonus tiers 5000/2000/1000/500/250/0 five points apart, a countdown of
// 30% of the total a tick (at least 1), no waits between the states, two
// perfect-game awards of 1000, and money at 5 a coin.
@(private = "file")
tally_defs :: proc() -> ^sim.Defs {
	d := synthetic_defs()
	d.perm_floats[0xbc] = 5
	for v, i in ([6]f32{5000, 2000, 1000, 500, 250, 0}) {
		d.perm_floats[0xbd + i] = v
	}
	d.perm_floats[0xc7] = 1
	d.perm_floats[0xc8] = 0.3
	d.perm_floats[0xcb] = 4 // fade steps a step, down
	d.perm_floats[0xcc] = 8 // and up
	d.perm_floats[0xcd] = 1000 // each perfect-game award
	d.perm_floats[0xd0] = 2 // how many
	d.perm_floats[0xab] = 5 // money multiplier
	d.perm_sounds[0x14] = TICK
	d.perm_sounds[0x15] = NIL_BONUS
	d.perm_sounds[0x16] = PERFECT_LEVEL
	d.perm_sounds[0x17] = PERFECT_GAME
	return d
}

@(private = "file")
Tally_Run :: struct {
	states:   [dynamic]i32, // the tally's states, as entered
	at:       [dynamic]int, // the step each was entered on
	sounds:   [dynamic]sim.Res_ID,
	entering: [11]sim.Res_ID, // the sound on entering each state
	steps:    int,
}

// The level end from its first step until it is complete (or `limit`
// steps), one step a time unit apart.
@(private = "file")
run_level_end :: proc(s: ^sim.State, limit: int) -> (r: Tally_Run) {
	l := sim.single(s, sim.Level_End)
	for i in 0 ..< limit {
		s.sounds.count = 0
		before := l.state
		level_system.level_end_step(s, i32(i))
		// The level end's own sounds: a score that earns a life has one too.
		played := sim.NONE
		for ev in s.sounds.events[:s.sounds.count] {
			switch ev.id {
			case TICK, NIL_BONUS, PERFECT_LEVEL, PERFECT_GAME:
				append(&r.sounds, ev.id)
				played = ev.id
			}
		}
		if l.state != before {
			append(&r.states, l.state)
			append(&r.at, i)
			r.entering[l.state] = played
		}
		r.steps = i + 1
		if l.complete {
			break
		}
	}
	return
}

@(private = "file")
count_of :: proc(ids: []sim.Res_ID, id: sim.Res_ID) -> (n: int) {
	for x in ids {
		if x == id {
			n += 1
		}
	}
	return
}

// FUN_00420930: the tiers step down from 100% by whole multiples of the
// gap, and the bonus is the tier's times the level number.
@(test)
level_end_bonus_tiers_step_down_by_the_gap :: proc(t: ^testing.T) {
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	defs := tally_defs()
	s := new(sim.State)
	Case :: struct {
		percent: i32,
		level:   i32,
		bonus:   i32,
	}
	cases := [?]Case{{96, 1, 2000}, {95, 1, 2000}, {91, 1, 1000}, {86, 1, 500}, {81, 1, 250}, {80, 1, 250}, {79, 1, 0}, {96, 3, 6000}}
	for c in cases {
		sim.init(s, sim.Session{seed = 3, level_id = sim.level_id("le01"), game_type = .Single}, defs)
		sim.single(s, sim.Level_Info).number = c.level
		sim.single(s, sim.Accuracy).targets, sim.single(s, sim.Accuracy).destroyed = 100, c.percent
		level_system.level_end_step(s, 0)
		testing.expectf(t, sim.single(s, sim.Level_End).bonus == c.bonus, "%d%% on level %d: bonus %d, want %d", c.percent, c.level, sim.single(s, sim.Level_End).bonus, c.bonus)
		testing.expect(t, !sim.single(s, sim.Accuracy).perfect_level)
	}
}

// FUN_00420d90 and the money counters, end to end: the readout's states in
// order, the bonus counted down a step a tick until it would go below zero
// (every tick awards the whole step, the last one included), then each
// player's money counted into the score, and the level complete.
@(test)
level_end_counts_down_the_bonus_then_the_money :: proc(t: ^testing.T) {
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	defs := tally_defs()
	s := new(sim.State)
	sim.init(s, sim.Session{seed = 3, level_id = sim.level_id("le01"), game_type = .Single}, defs)
	sim.single(s, sim.Accuracy).targets, sim.single(s, sim.Accuracy).destroyed = 50, 47 // 94%
	p := sim.player_at(s, 0)
	p.money = 10
	score := p.score
	r := run_level_end(s, 200)
	l := sim.single(s, sim.Level_End)

	testing.expect(t, l.complete, "the level end must finish")
	testing.expect_value(t, len(r.states), 8)
	for st, i in r.states {
		testing.expect_value(t, st, i32(i + 1))
	}
	// 1000 in steps of 300: four ticks, the bonus stopping at nothing.
	testing.expect_value(t, l.bonus_total, i32(1000))
	testing.expect_value(t, l.bonus_step, i32(300))
	testing.expect_value(t, l.bonus, i32(0))
	testing.expect_value(t, r.entering[5], TICK) // a bonus that is neither 0 nor perfect
	testing.expect_value(t, count_of(r.sounds[:], NIL_BONUS), 0)
	testing.expect_value(t, count_of(r.sounds[:], PERFECT_LEVEL), 0)
	testing.expect_value(t, l.perfect_levels, i32(0))
	testing.expect(t, !l.perfect)

	// The money: 10 coins at 5 is 50, in steps of 15 (30%): four ticks.
	testing.expect_value(t, p.counter.multiplier, i32(5))
	testing.expect_value(t, p.counter.step, i32(15))
	testing.expect(t, p.counter.value < 1, "the money counter must run out")
	testing.expect_value(t, p.money, i32(6))
	testing.expect_value(t, p.score - score, (4 * 300 + 4 * 15) * p.multiplier)
	// The readout's ticks: states 2-5 and four counts each, for both.
	testing.expect_value(t, count_of(r.sounds[:], TICK), 16)
}

// Every level of the list at 100%: once the readout ends, the perfect-game
// bonus plays, awarding its flat score as many times as perm float 0xd0
// says, each after a wait of perm float 0xcf steps, before the money
// counters run. A perm sound left as none is silent.
@(test)
a_perfect_game_awards_the_perfect_bonus :: proc(t: ^testing.T) {
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	defs := tally_defs()
	defs.perm_sounds[0x14] = sim.NONE
	defs.perm_floats[0xcf] = 3 // the steps before each award
	s := new(sim.State)
	sim.init(s, sim.Session{seed = 3, level_id = sim.level_id("le01"), game_type = .Single}, defs)
	sim.single(s, sim.Accuracy).targets, sim.single(s, sim.Accuracy).destroyed = 20, 20
	p := sim.player_at(s, 0)
	score := p.score
	r := run_level_end(s, 200)
	l := sim.single(s, sim.Level_End)

	testing.expect(t, l.complete, "the level end must finish")
	testing.expect(t, sim.single(s, sim.Accuracy).perfect_level)
	testing.expect_value(t, l.perfect_levels, i32(1))
	want := [?]i32{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 9, 10}
	if testing.expect_value(t, len(r.states), len(want)) {
		for st, i in r.states {
			testing.expect_value(t, st, want[i])
		}
	}
	testing.expect_value(t, l.perfect_count, i32(2))
	// An award, and the return to state 9 with it, comes once more than
	// 0xcf steps have passed in state 10.
	if len(r.at) == len(want) {
		testing.expect_value(t, r.at[10] - r.at[9], 4)
	}
	testing.expect(t, !l.perfect, "the perfect-game bonus ends after its awards")
	// No ticks (sound none): the level's perfect sound, the game's once as
	// its bonus starts, and the money counter's for nothing to count.
	sounds := [?]sim.Res_ID{PERFECT_LEVEL, PERFECT_GAME, NIL_BONUS}
	if testing.expect_value(t, len(r.sounds), len(sounds)) {
		for id, i in r.sounds {
			testing.expect_value(t, id, sounds[i])
		}
	}
	// Tier 5000 for level 1 in steps of 1500: four ticks of 1500, and the
	// two flat awards, which the multiplier does not touch.
	testing.expect_value(t, p.score - score, 4 * 1500 * p.multiplier + 2 * 1000)
}

// G_Player::MoneyCounter_Start: with perm float 0xaa set the multiplier
// grows with the level number. A player not in the game has no counter,
// and an idle counter counts as finished.
@(test)
money_counter_multiplier_grows_with_the_level :: proc(t: ^testing.T) {
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	defs := tally_defs()
	defs.perm_floats[0xaa] = 1
	s := new(sim.State)
	sim.init(s, sim.Session{seed = 3, level_id = sim.level_id("le01"), game_type = .Single}, defs)
	sim.single(s, sim.Level_Info).number = 3
	p := sim.player_at(s, 0)
	p.money = 4
	testing.expect(t, level_system.money_counter_start(s, p, 0, false))
	testing.expect_value(t, p.counter.multiplier, i32(15))
	testing.expect_value(t, p.counter.value, i32(60))

	p2 := sim.player_at(s, 1)
	testing.expect(t, !p2.active)
	testing.expect(t, !level_system.money_counter_start(s, p2, 0, false), "no counter for a player not in the game")
	testing.expect(t, !level_system.money_counter_active(p2))
	testing.expect(t, level_system.money_counter_process(s, p2, 1), "an idle counter is finished")
}

// Notices and the background.

// G_Notice_Request ignores an entry or destruct notice that is empty or
// "none": nothing shows, and the slot stays free for the next.
@(test)
an_empty_or_none_notice_shows_nothing :: proc(t: ^testing.T) {
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := new(sim.State)
	sim.init(s, sim.Session{seed = 3, level_id = sim.level_id("le01"), game_type = .Single}, synthetic_defs())
	for text in ([2]string{"", "none"}) {
		u := sim.Unit{entry_notice = text, entry_notice_sound = sim.res_id("snd1")}
		notice_system.notice_request(s, &u, 0)
		notice_system.notice_request_destruct(s, text)
	}
	testing.expect_value(t, s.notices.count, 0)
	testing.expect(t, !sim.single(s, sim.Notice_State).pending)
	notice_system.notice_request_destruct(s, "Shown")
	testing.expect_value(t, s.notices.count, 1)
}

// FUN_00410490: the view scrolls up to the top of the map and stops there,
// its bottom a screen below the top, and reports no rows scrolled once it
// can go no further.
@(test)
the_view_stops_at_the_top_of_the_map :: proc(t: ^testing.T) {
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := new(sim.State)
	defs := synthetic_defs()
	sim.init(s, sim.Session{seed = 3, level_id = sim.level_id("le01"), game_type = .Single}, defs)
	h := sim.view_height(defs)
	b := sim.single(s, sim.Bgnd)
	b.speed = 1
	b.view_top, b.view_bottom = 2, 2 + h
	background_system.bgnd_scroll(s)
	testing.expect_value(t, b.view_top, i32(1))
	testing.expect_value(t, b.scrolled, i32(1))
	background_system.bgnd_scroll(s)
	testing.expect_value(t, b.view_top, i32(0))
	testing.expect_value(t, b.view_bottom, h)
	testing.expect_value(t, b.scrolled, i32(1))
	background_system.bgnd_scroll(s)
	testing.expect_value(t, b.view_top, i32(0))
	testing.expect_value(t, b.view_bottom, h)
	testing.expect_value(t, b.scrolled, i32(0))
}
