package tests

import "base:runtime"
import "core:reflect"
import "core:testing"
import vmem "core:mem/virtual"

import "dr:sim"
import "dr:sim/lifecycle"

// The entity lifecycle (sim/lifecycle): spawning groups, changing state,
// destroying and sweeping. These pin how the port reads G_EG_* and
// G_Entity::* on paths no shipped unit takes, or that the golden runs never
// reach, so each builds the units it needs on synthetic_defs' empty level.
// The procedures under test are called directly: no session is stepped, so
// nothing but the call under test draws from the RNG.

@(private = "file")
Lc_Fixture :: struct {
	arena:  vmem.Arena,
	defs:   ^sim.Defs,
	units:  [dynamic]sim.Unit,
	s:      ^sim.State,
	events: sim.Event_Log,
	draws:  sim.Draw_Log,
}

// Every Res_ID field of a definition set to "none", as the original's
// SetToDefaults leaves an unset id. A zero id is not "none": the lifecycle
// would try to spawn it.
@(private = "file")
lc_all_none :: proc(p: ^$T) {
	for f in reflect.struct_fields_zipped(T) {
		if f.type.id == typeid_of(sim.Res_ID) {
			(^sim.Res_ID)(uintptr(p) + f.offset)^ = sim.NONE
		}
	}
}

// A state that does nothing: no sprite, no timer, no spawns.
@(private = "file")
lc_state :: proc(name: string) -> (st: sim.Unit_State) {
	lc_all_none(&st.def)
	st.name = name
	st.num_directions, st.frames_per_direction = 1, 1
	st.required_scale_percent, st.required_visibility_percent = 100, 100
	return
}

@(private = "file")
lc_states :: proc(u: ^sim.Unit, names: ..string) {
	u.states = make([]sim.Unit_State, len(names))
	for n, i in names {
		u.states[i] = lc_state(n)
	}
}

// Starts the arena and a copy of synthetic_defs; returns the arena's
// allocator, which the test makes its context's.
@(private = "file")
lc_begin :: proc(t: ^testing.T, f: ^Lc_Fixture) -> runtime.Allocator {
	testing.expect(t, vmem.arena_init_growing(&f.arena) == nil)
	alloc := vmem.arena_allocator(&f.arena)
	f.defs = new_clone(synthetic_defs()^, alloc)
	f.units = make([dynamic]sim.Unit, alloc)
	return alloc
}

// Adds one plain unit per id: a group of one that always appears, fully
// visible, at its group's location, with one idle state.
@(private = "file")
lc_units :: proc(f: ^Lc_Fixture, ids: ..string) {
	for id in ids {
		u := sim.Unit{id = sim.res_id(id)}
		lc_all_none(&u.def)
		u.num_in_group_min, u.num_in_group_max = 1, 1
		u.appears_percent = 100
		u.initial_visibility_percent = 100
		u.initial_scale_percent = 100
		lc_states(&u, "Idle")
		append(&f.units, u)
	}
	f.defs.units = f.units[:]
}

// A unit added by lc_units. Good until the next lc_units call.
@(private = "file")
lc_unit :: proc(f: ^Lc_Fixture, id: string) -> ^sim.Unit {
	return sim.unit_find(f.defs, sim.res_id(id))
}

@(private = "file")
lc_start :: proc(f: ^Lc_Fixture) {
	f.events = {events = make([]sim.Event, 2048)}
	f.draws = {draws = make([]sim.Draw, 2048)}
	f.s = new(sim.State)
	sim.init(f.s, sim.Session{seed = 1, level_id = sim.level_id("le01"), game_type = .Single}, f.defs, &f.draws, &f.events)
}

@(private = "file")
lc_time :: proc(f: ^Lc_Fixture) -> i32 {
	return sim.single(f.s, sim.Clock).time
}

@(private = "file")
lc_spawn :: proc(
	t: ^testing.T,
	f: ^Lc_Fixture,
	id: string,
	loc := sim.Vec{200, 100},
	owner_player: i32 = -1,
	owner := sim.NO_REF,
	stationary := false,
) -> (
	e: sim.Entity,
	r: sim.Entity_Ref,
	ok: bool,
) {
	req := sim.spawn_request(sim.res_id(id))
	req.loc = loc
	req.owner_player = owner_player
	req.owner = owner
	req.stationary = stationary
	r = lifecycle.eg_request_spawn(f.s, req)
	if !testing.expectf(t, sim.ref_valid(f.s, r), "%s must spawn", id) {
		return
	}
	return sim.entity_at(f.s, r.index), r, true
}

// Sets the session's RNG so that its next RandomInt(lo, hi) draws `want`,
// so a test picks the outcome of one of the original's draws.
@(private = "file")
lc_rig :: proc(f: ^Lc_Fixture, lo, hi, want: i32) {
	for seed in u32(1) ..< 1 << 20 {
		r := sim.rand_init(seed)
		if sim.random_int(&r, lo, hi, 0) == want {
			sim.single(f.s, sim.Rng).next = seed
			return
		}
	}
	panic("no seed draws that value")
}

// Spawn requests logged since the event log was last emptied, of `id`.
@(private = "file")
lc_spawn_requests :: proc(f: ^Lc_Fixture, id: sim.Res_ID) -> (n: int) {
	for e in sim.event_log_entries(&f.events) {
		if e.kind == .Spawn && e.unit == id {
			n += 1
		}
	}
	return
}

@(private = "file")
lc_all_spawn_requests :: proc(f: ^Lc_Fixture) -> (n: int, last: sim.Res_ID) {
	for e in sim.event_log_entries(&f.events) {
		if e.kind == .Spawn {
			n, last = n + 1, e.unit
		}
	}
	return
}

// The live (not deleted) pool entities of a unit, and the last of them.
@(private = "file")
lc_live :: proc(f: ^Lc_Fixture, id: string) -> (n: int, last: sim.Entity) {
	ui := sim.unit_index(f.defs, sim.res_id(id))
	for used, i in sim.single(f.s, sim.Pool).entity_used {
		if !used {
			continue
		}
		if e := sim.entity_at(f.s, i32(i)); !e.deleted && e.unit == ui {
			n, last = n + 1, e
		}
	}
	return
}

// A draw at `site` among those logged since the draw log was last emptied.
@(private = "file")
lc_draw_at :: proc(f: ^Lc_Fixture, site: sim.Site) -> (d: sim.Draw, ok: bool) {
	for x in sim.draw_log_entries(&f.draws) {
		if x.site == site {
			return x, true
		}
	}
	return
}

// A 4 x 30 media mask at 120 map pixels a mask pixel: the first column is
// land, the rest water. CanSpawnOnMedia reads the pixel under
// (x + 32, view_top + y).
@(private = "file")
lc_water_mask :: proc(f: ^Lc_Fixture) {
	l := &f.defs.levels[0]
	l.media_w, l.media_h, l.media_scale = 4, 30, 120
	l.media = make([]u16, 4 * 30)
	for &p, i in l.media {
		p = i % 4 == 0 ? 0 : 0x1f
	}
}

// G_Entity::Destroy leaves a ground unit's destructSpawn behind unless it
// dies over water (CanSpawnOnMedia): with no mask, or off the mask's edge,
// or over land, the remains appear, at the unit's location and owned by
// it; over water only its splash does, unless the unit may leave its
// remains on any media.
@(test)
destroy_leaves_ground_remains_except_over_water :: proc(t: ^testing.T) {
	f: Lc_Fixture
	defer vmem.arena_destroy(&f.arena)
	context.allocator = lc_begin(t, &f)
	lc_units(&f, "tank", "wrek", "spl6", "spl7", "spl8", "spl9")
	tank := lc_unit(&f, "tank")
	tank.is_ground_based = true
	tank.destruct_spawn = sim.res_id("wrek")
	tank.media_impact_size = sim.res_id("smal")
	for i in 6 ..= 9 {
		f.defs.perm_objects[i] = sim.res_id(i == 6 ? "spl6" : i == 7 ? "spl7" : i == 8 ? "spl8" : "spl9")
	}
	lc_start(&f)

	die :: proc(t: ^testing.T, f: ^Lc_Fixture, loc: sim.Vec) -> (remains, splash: int) {
		e, _, ok := lc_spawn(t, f, "tank", loc)
		if !ok {
			return
		}
		number := e.number
		f.events.count = 0
		lifecycle.entity_destroy(f.s, e, 0, lc_time(f))
		remains = lc_spawn_requests(f, sim.res_id("wrek"))
		splash = lc_spawn_requests(f, sim.res_id("spl7"))
		if remains == 1 {
			// Left where it died, and owned by it.
			_, w := lc_live(f, "wrek")
			testing.expect_value(t, w.loc, loc)
			testing.expect_value(t, w.owner.number, number)
		}
		return
	}

	// The level has no mask: nothing is water.
	remains, splash := die(t, &f, {200, 100})
	testing.expect(t, remains == 1 && splash == 0, "with no media mask the remains appear")

	lc_water_mask(&f)
	remains, splash = die(t, &f, {500, 100}) // x + 32 is past the mask's right edge
	testing.expect(t, remains == 1 && splash == 0, "off the mask is not water")
	remains, splash = die(t, &f, {50, 100}) // the land column
	testing.expect(t, remains == 1 && splash == 0, "over land the remains appear")
	remains, splash = die(t, &f, {200, 100})
	testing.expect(t, remains == 0 && splash == 1, "over water only the splash appears")

	tank.do_death_spawn_on_any_media = true
	remains, splash = die(t, &f, {200, 100})
	testing.expect(t, remains == 1 && splash == 0, "doDeathSpawnOnAnyMedia leaves the remains over water")
}

// The splash a ground unit makes over water is chosen by its mediaImpactSize:
// perm objects 6..9, fixed for four sizes and drawn for the three mixed ones,
// each at its own RandomInt call site. An unknown size splashes nothing, and
// still leaves no remains.
@(test)
water_splash_follows_the_media_impact_size :: proc(t: ^testing.T) {
	f: Lc_Fixture
	defer vmem.arena_destroy(&f.arena)
	context.allocator = lc_begin(t, &f)
	lc_units(&f, "tank", "wrek", "spl6", "spl7", "spl8", "spl9")
	tank := lc_unit(&f, "tank")
	tank.is_ground_based = true
	tank.destruct_spawn = sim.res_id("wrek")
	splashes := [4]string{"spl6", "spl7", "spl8", "spl9"}
	for id, i in splashes {
		f.defs.perm_objects[6 + i] = sim.res_id(id)
	}
	lc_water_mask(&f)
	lc_start(&f)

	Case :: struct {
		size: string,
		hi:   i32, // the draw is RandomInt(0, hi); 0 for no draw
		roll: i32,
		site: sim.Site,
		want: int, // perm object index, or -1 for no splash
	}
	cases := []Case {
		{"med ", 0, 0, 0, 8},
		{"larg", 0, 0, 0, 9},
		{"smal", 0, 0, 0, 7},
		{"tiny", 0, 0, 0, 6},
		{"lara", 1, 0, 0x415ba7, 9},
		{"lara", 1, 1, 0x415ba7, 8},
		{"mera", 2, 0, 0x415b4e, 6},
		{"mera", 2, 1, 0x415b4e, 7},
		{"mera", 2, 2, 0x415b4e, 8},
		{"smra", 1, 0, 0x415afe, 7},
		{"smra", 1, 1, 0x415afe, 6},
		{"huge", 0, 0, 0, -1},
	}
	for c in cases {
		tank.media_impact_size = sim.res_id(c.size)
		e, _, ok := lc_spawn(t, &f, "tank", {200, 100})
		if !ok {
			return
		}
		if c.hi > 0 {
			lc_rig(&f, 0, c.hi, c.roll)
		}
		f.events.count, f.draws.count = 0, 0
		lifecycle.entity_destroy(f.s, e, 0, lc_time(&f))
		n, last := lc_all_spawn_requests(&f)
		if c.want < 0 {
			testing.expectf(t, n == 0, "%q: no splash and no remains, got %d spawns", c.size, n)
		} else {
			testing.expectf(t, n == 1 && last == f.defs.perm_objects[c.want], "%q roll %d: want perm object %d, got %d spawns, last %v", c.size, c.roll, c.want, n, last)
		}
		for site in ([]sim.Site{0x415ba7, 0x415b4e, 0x415afe}) {
			_, drew := lc_draw_at(&f, site)
			testing.expectf(t, drew == (site == c.site), "%q: draw at %x %v", c.size, site, drew)
		}
	}
}

// G_Entity::Destroy shows the unit's destructNotice, unless it is "none".
@(test)
destroy_shows_the_destruct_notice :: proc(t: ^testing.T) {
	f: Lc_Fixture
	defer vmem.arena_destroy(&f.arena)
	context.allocator = lc_begin(t, &f)
	lc_units(&f, "sign", "quie")
	lc_unit(&f, "sign").destruct_notice = "Target down"
	lc_unit(&f, "quie").destruct_notice = "none"
	lc_start(&f)

	q, _, ok := lc_spawn(t, &f, "quie")
	if !ok {
		return
	}
	lifecycle.entity_destroy(f.s, q, 0, lc_time(&f))
	testing.expect_value(t, f.s.notices.count, 0)
	e, _, ok2 := lc_spawn(t, &f, "sign")
	if !ok2 {
		return
	}
	lifecycle.entity_destroy(f.s, e, 0, lc_time(&f))
	if testing.expect_value(t, f.s.notices.count, 1) {
		testing.expect_value(t, f.s.notices.events[0].text, "Target down")
	}
}

// The random bonus at the end of G_Entity::Destroy: one RandomInt(0, 100)
// against the cumulative percentages in perm floats 0xd1..0xd9 picks one of
// RandomBonus_1..10 (perm objects 0x19..0x22). Two twists: on a level
// earned by a perfect one (reward_this_level), a roll under perm float 0xda
// in the first band gives RandomBonus_6 once instead; and before the level
// in perm float 0xdb, everything from the eighth band up gives
// RandomBonus_8.
@(test)
random_bonus_follows_the_cumulative_percentages :: proc(t: ^testing.T) {
	f: Lc_Fixture
	defer vmem.arena_destroy(&f.arena)
	context.allocator = lc_begin(t, &f)
	bonuses := [10]string{"bn01", "bn02", "bn03", "bn04", "bn05", "bn06", "bn07", "bn08", "bn09", "bn10"}
	lc_units(&f, "crat")
	lc_units(&f, ..bonuses[:])
	lc_unit(&f, "crat").destruct_release_random_bonus = true
	for id, i in bonuses {
		f.defs.perm_objects[0x19 + i] = sim.res_id(id)
	}
	for i in 0 ..< 9 {
		f.defs.perm_floats[0xd1 + i] = f32(10 * (i + 1)) // bands of 10: 0-9, 10-19, ...
	}
	f.defs.perm_floats[0xda] = 5
	lc_start(&f)

	Case :: struct {
		reward:  bool,
		from:    f32, // perm float 0xdb: the first level with the top bands
		roll:    i32,
		want:    int, // the perm object
		reward_after: bool,
	}
	cases := []Case {
		{false, 0, 0, 0x19, false},
		{false, 0, 9, 0x19, false},
		{false, 0, 10, 0x1a, false},
		{false, 0, 25, 0x1b, false},
		{false, 0, 35, 0x1c, false},
		{false, 0, 45, 0x1d, false},
		{false, 0, 55, 0x1e, false},
		{false, 0, 65, 0x1f, false},
		{false, 0, 75, 0x20, false},
		{false, 0, 85, 0x21, false},
		{false, 0, 95, 0x22, false},
		{false, 0, 100, 0x22, false},
		// The reward: under 0xda it is RandomBonus_6, and spent.
		{true, 0, 4, 0x1e, false},
		// At or over 0xda it is the first band's bonus, and kept.
		{true, 0, 5, 0x19, true},
		{true, 0, 15, 0x1a, true},
		// Level 1 is before level 2: the top bands give RandomBonus_8.
		{false, 2, 85, 0x20, false},
		{false, 2, 95, 0x20, false},
		{false, 2, 65, 0x1f, false},
	}
	acc := sim.single(f.s, sim.Accuracy)
	for c in cases {
		e, _, ok := lc_spawn(t, &f, "crat")
		if !ok {
			return
		}
		acc.reward_this_level = c.reward
		f.defs.perm_floats[0xdb] = c.from
		lc_rig(&f, 0, 100, c.roll)
		f.events.count = 0
		lifecycle.entity_destroy(f.s, e, 0, lc_time(&f))
		n, last := lc_all_spawn_requests(&f)
		testing.expectf(t, n == 1 && last == f.defs.perm_objects[c.want], "%v: want perm object %x, got %d spawns, last %v", c, c.want, n, last)
		testing.expectf(t, acc.reward_this_level == c.reward_after, "%v: reward left %v", c, acc.reward_this_level)
	}
}

// A stationary unit that makes an obstacle on destruction is already one
// where it is placed: G_EG marks its bounds as debris as it spawns. Moving,
// it marks nothing.
@(test)
stationary_obstacle_marks_debris_as_it_spawns :: proc(t: ^testing.T) {
	f: Lc_Fixture
	defer vmem.arena_destroy(&f.arena)
	context.allocator = lc_begin(t, &f)
	lc_units(&f, "bunk")
	bunk := lc_unit(&f, "bunk")
	bunk.is_ground_based = true
	bunk.destruct_create_obstacle = true
	bunk.states[0].sprite_face = sim.res_id("bunk")
	sprites := make([]sim.Sprite, 1)
	sprites[0] = {id = sim.res_id("bunk"), frames = make([]sim.Sprite_Frame, 1)}
	sprites[0].frames[0] = {16, 10}
	f.defs.sprites = sprites
	lc_start(&f)

	debris := sim.single(f.s, sim.Debris)
	before := debris.count
	if _, _, ok := lc_spawn(t, &f, "bunk", {200, 100}); !ok {
		return
	}
	testing.expect_value(t, debris.count, before)
	if _, _, ok := lc_spawn(t, &f, "bunk", {200, 100}, stationary = true); !ok {
		return
	}
	if testing.expect_value(t, debris.count, before + 1) {
		testing.expect_value(t, debris.rects[before], sim.Rect{top = 95, left = 192, bottom = 105, right = 208})
	}
}

// G_EG_ResetAtLevelStart turns the level's placements into required groups:
// a placement naming no unit, or a unit that does not exist, is skipped, and
// a ground unit's group sits 32 pixels left of where it was placed.
@(test)
level_placements_skip_missing_units_and_shift_ground_units :: proc(t: ^testing.T) {
	f: Lc_Fixture
	defer vmem.arena_destroy(&f.arena)
	context.allocator = lc_begin(t, &f)
	lc_units(&f, "tank", "jet ")
	lc_unit(&f, "tank").is_ground_based = true
	placements := make([]sim.Placement_Def, 4)
	placements[0] = {unit = sim.NONE, x = 10, y = 20}
	placements[1] = {unit = sim.res_id("zzzz"), x = 10, y = 20}
	placements[2] = {unit = sim.res_id("tank"), x = 100, y = 200, heading = 90, stationary = true}
	placements[3] = {unit = sim.res_id("jet "), x = 50, y = 60}
	f.defs.levels[0].placements = placements
	lc_start(&f)

	// Rows 200 and 60 are far above the view, so both are still waiting.
	w := sim.single(f.s, sim.Pool)
	if !testing.expect_value(t, w.required.count, 2) {
		return
	}
	c := sim.Cursor{sim.NO_LINK}
	tank := sim.group_at(f.s, sim.list_next(&w.required, sim.group_links(f.s), &c))
	testing.expect_value(t, tank.unit, sim.res_id("tank"))
	testing.expect_value(t, tank.loc, sim.Vec{68, 200})
	testing.expect_value(t, tank.heading, 90)
	testing.expect(t, tank.stationary)
	testing.expect_value(t, tank.id, -1)
	jet := sim.group_at(f.s, sim.list_next(&w.required, sim.group_links(f.s), &c))
	testing.expect_value(t, jet.unit, sim.res_id("jet "))
	testing.expect_value(t, jet.loc, sim.Vec{50, 60})
}

// FUN_0041b650: a group's size bounds that cross (min above max) collapse to
// the max, without a draw; a unit whose max is 0 makes a group of none, and
// a request for it spawns nothing.
@(test)
group_size_uses_the_max_when_the_bounds_cross :: proc(t: ^testing.T) {
	f: Lc_Fixture
	defer vmem.arena_destroy(&f.arena)
	context.allocator = lc_begin(t, &f)
	lc_units(&f, "zero", "pair")
	lc_unit(&f, "zero").num_in_group_min, lc_unit(&f, "zero").num_in_group_max = 0, 0
	lc_unit(&f, "pair").num_in_group_min, lc_unit(&f, "pair").num_in_group_max = 3, 2
	lc_start(&f)

	f.draws.count = 0
	testing.expect_value(t, lifecycle.group_size(f.s, lc_unit(&f, "pair")), 2)
	testing.expect_value(t, lifecycle.group_size(f.s, lc_unit(&f, "zero")), 0)
	testing.expect_value(t, f.draws.count, 0)

	r := lifecycle.eg_request_spawn(f.s, sim.spawn_request(sim.res_id("zero")))
	testing.expect_value(t, r, sim.NO_REF)
	r = lifecycle.eg_request_spawn(f.s, sim.spawn_request(sim.res_id("pair")))
	testing.expect(t, sim.ref_valid(f.s, r))
	n, _ := lc_live(&f, "pair")
	testing.expect_value(t, n, 2)
}

// doNotSpawnIfTypeAlreadyExists: while an entity of the unit is in the pool
// (FUN_0041b740 walks the groups, so one deleted but not yet swept counts)
// a request for another is refused; once it is swept, one may spawn again.
@(test)
unique_unit_is_refused_while_one_is_in_the_pool :: proc(t: ^testing.T) {
	f: Lc_Fixture
	defer vmem.arena_destroy(&f.arena)
	context.allocator = lc_begin(t, &f)
	lc_units(&f, "boss", "mob ")
	lc_unit(&f, "boss").do_not_spawn_if_type_already_exists = true
	lc_start(&f)

	boss := sim.res_id("boss")
	testing.expect_value(t, lifecycle.count_of_unit(f.s, boss), 0)
	e, _, ok := lc_spawn(t, &f, "boss")
	if !ok {
		return
	}
	lc_spawn(t, &f, "mob ")
	testing.expect_value(t, lifecycle.count_of_unit(f.s, boss), 1)
	testing.expect_value(t, lifecycle.eg_request_spawn(f.s, sim.spawn_request(boss)), sim.NO_REF)

	lifecycle.entity_delete(e)
	testing.expect_value(t, lifecycle.eg_request_spawn(f.s, sim.spawn_request(boss)), sim.NO_REF)
	lifecycle.sweep_deleted(f.s)
	testing.expect_value(t, lifecycle.count_of_unit(f.s, boss), 0)
	testing.expect(t, sim.ref_valid(f.s, lifecycle.eg_request_spawn(f.s, sim.spawn_request(boss))))
}

// G_EG_RequestSpawn refuses a whole group that would take the pool past
// 1000 ("Reached Entity Limit"), even when some of it would fit, and says
// so once in limit_warned.
@(test)
spawn_refuses_a_group_past_the_entity_limit :: proc(t: ^testing.T) {
	f: Lc_Fixture
	defer vmem.arena_destroy(&f.arena)
	context.allocator = lc_begin(t, &f)
	lc_units(&f, "dot ", "pair")
	lc_unit(&f, "pair").num_in_group_min, lc_unit(&f, "pair").num_in_group_max = 2, 2
	lc_start(&f)

	w := sim.single(f.s, sim.Pool)
	dot := sim.spawn_request(sim.res_id("dot "))
	for w.used_count < sim.MAX_ENTITIES - 1 {
		if !testing.expect(t, sim.ref_valid(f.s, lifecycle.eg_request_spawn(f.s, dot))) {
			return
		}
	}
	testing.expect(t, !w.limit_warned)
	testing.expect_value(t, lifecycle.eg_request_spawn(f.s, sim.spawn_request(sim.res_id("pair"))), sim.NO_REF)
	testing.expect(t, w.limit_warned, "the refusal is noted")
	testing.expect_value(t, w.used_count, sim.MAX_ENTITIES - 1)
	testing.expect(t, sim.ref_valid(f.s, lifecycle.eg_request_spawn(f.s, dot)), "one still fits")
	testing.expect_value(t, lifecycle.eg_request_spawn(f.s, dot), sim.NO_REF)
	testing.expect_value(t, w.used_count, sim.MAX_ENTITIES)
}

// deleteExistingEntitiesOfThisTypeOwnedByPlayer (FUN_0041b820): a player's
// new entity of the unit replaces the one they had; another player's, or
// one owned by no player, is left alone.
@(test)
a_players_new_entity_replaces_their_old_one :: proc(t: ^testing.T) {
	f: Lc_Fixture
	defer vmem.arena_destroy(&f.arena)
	context.allocator = lc_begin(t, &f)
	lc_units(&f, "shld")
	lc_unit(&f, "shld").delete_existing_entities_of_this_type_owned_by_player = true
	lc_start(&f)

	a, _, ok1 := lc_spawn(t, &f, "shld", owner_player = 0)
	b, _, ok2 := lc_spawn(t, &f, "shld", owner_player = 1)
	nobody, _, ok3 := lc_spawn(t, &f, "shld")
	if !ok1 || !ok2 || !ok3 {
		return
	}
	testing.expect(t, !a.deleted && !b.deleted && !nobody.deleted)
	c, _, ok := lc_spawn(t, &f, "shld", owner_player = 0)
	if !ok {
		return
	}
	testing.expect(t, a.deleted, "player 0's old one goes")
	testing.expect(t, !a.destroyed, "deleted, not destroyed")
	testing.expect(t, !b.deleted && !nobody.deleted && !c.deleted)
	// Owned by no player, a new one replaces nothing.
	if _, _, ok4 := lc_spawn(t, &f, "shld"); !ok4 {
		return
	}
	testing.expect(t, !nobody.deleted && !c.deleted)
}

// G_EG_RequestSpawn shows the unit's entryNotice once the group is spawned.
@(test)
spawn_shows_the_entry_notice :: proc(t: ^testing.T) {
	f: Lc_Fixture
	defer vmem.arena_destroy(&f.arena)
	context.allocator = lc_begin(t, &f)
	lc_units(&f, "anno")
	anno := lc_unit(&f, "anno")
	anno.entry_notice = "Warning"
	anno.entry_notice_sound = sim.NONE
	lc_start(&f)

	testing.expect_value(t, f.s.notices.count, 0)
	if _, _, ok := lc_spawn(t, &f, "anno"); !ok {
		return
	}
	if testing.expect_value(t, f.s.notices.count, 1) {
		testing.expect_value(t, f.s.notices.events[0].text, "Warning")
	}
}

// SetUnitRef notes whether any of the unit's states is one to enter when
// shields run out (useThisStateOnShieldDepletion).
@(test)
entity_knows_its_unit_has_a_depletion_state :: proc(t: ^testing.T) {
	f: Lc_Fixture
	defer vmem.arena_destroy(&f.arena)
	context.allocator = lc_begin(t, &f)
	lc_units(&f, "armr", "soft")
	armr := lc_unit(&f, "armr")
	lc_states(armr, "Idle", "Broken")
	armr.states[1].use_this_state_on_shield_depletion = true
	lc_start(&f)

	a, _, ok1 := lc_spawn(t, &f, "armr")
	s, _, ok2 := lc_spawn(t, &f, "soft")
	if ok1 && ok2 {
		testing.expect(t, a.has_depletion_state)
		testing.expect(t, !s.has_depletion_state)
	}
}

// Headings wrap once into 0..359 after the tolerance is added, and one
// still out of range falls back to 0: in SetUnitRef for a given heading
// (FUN_0041a990), and in the initial velocity for the unit's own
// (FUN_0041c840).
@(test)
spawn_headings_wrap_once_then_fall_back_to_zero :: proc(t: ^testing.T) {
	f: Lc_Fixture
	defer vmem.arena_destroy(&f.arena)
	context.allocator = lc_begin(t, &f)
	lc_units(&f, "turn", "drft")
	lc_unit(&f, "turn").initial_heading_tolerance = 2
	lc_unit(&f, "drft").initial_heading_tolerance = 10
	lc_start(&f)

	// A given heading of 900: 899..901 wraps to 539..541, still out of range.
	req := sim.spawn_request(sim.res_id("turn"))
	req.explicit_heading, req.heading = true, 900
	if r := lifecycle.eg_request_spawn(f.s, req); testing.expect(t, sim.ref_valid(f.s, r)) {
		testing.expect_value(t, sim.entity_at(f.s, r.index).heading, 0)
	}

	drft := lc_unit(&f, "drft")
	Case :: struct {
		heading, roll, want: i32,
	}
	for c in ([]Case{{358, 4, 2}, {2, -4, 358}, {1000, 0, 0}}) {
		drft.initial_heading = c.heading
		// The tolerance, RandomInt(-5, 5) at 0x41caaa, is the spawn's first draw.
		lc_rig(&f, -5, 5, c.roll)
		if e, _, ok := lc_spawn(t, &f, "drft"); ok {
			testing.expectf(t, e.heading == c.want, "heading %d%+d: got %d, want %d", c.heading, c.roll, e.heading, c.want)
		}
	}
}

// FUN_0041c540 draws an offset between its bounds lowest first, whichever
// way round the definition gives them, when the other axis is fixed.
@(test)
reversed_offset_bounds_are_drawn_low_to_high :: proc(t: ^testing.T) {
	f: Lc_Fixture
	defer vmem.arena_destroy(&f.arena)
	context.allocator = lc_begin(t, &f)
	lc_units(&f, "xrev", "yrev")
	x := lc_unit(&f, "xrev")
	x.x_offset_min, x.x_offset_max = 10, -10
	x.y_offset_min, x.y_offset_max = 5, 5
	y := lc_unit(&f, "yrev")
	y.x_offset_min, y.x_offset_max = 3, 3
	y.y_offset_min, y.y_offset_max = 8, -8
	lc_start(&f)

	f.draws.count = 0
	if e, _, ok := lc_spawn(t, &f, "xrev", {200, 100}); ok {
		d, drew := lc_draw_at(&f, 0x41c718)
		testing.expect(t, drew && d.a == transmute(u32)i32(-10) && d.b == 10, "x drawn from -10 to 10")
		testing.expect(t, e.loc.x >= 190 && e.loc.x <= 210)
		testing.expect_value(t, e.loc.y, 105)
	}
	f.draws.count = 0
	if e, _, ok := lc_spawn(t, &f, "yrev", {200, 100}); ok {
		d, drew := lc_draw_at(&f, 0x41c7e8)
		testing.expect(t, drew && d.a == transmute(u32)i32(-8) && d.b == 8, "y drawn from -8 to 8")
		testing.expect_value(t, e.loc.x, 203)
		testing.expect(t, e.loc.y >= 92 && e.loc.y <= 108)
	}
}

// Paths the port has not ported yet record their original address, so the
// oracle diff expects a divergence from there: a pickup's weapon appearance
// in ChangeState, and a bursting unit's or an owner-heading unit's initial
// velocity. An owner-heading unit with no owner takes its own heading, which
// is ported.
@(test)
unported_spawn_paths_report_their_site :: proc(t: ^testing.T) {
	f: Lc_Fixture
	defer vmem.arena_destroy(&f.arena)
	context.allocator = lc_begin(t, &f)
	lc_units(&f, "pkup", "brst", "ownh", "base")
	lc_unit(&f, "brst").do_burst = true
	lc_unit(&f, "brst").initial_speed_min, lc_unit(&f, "brst").initial_speed_max = 3, 3
	ownh := lc_unit(&f, "ownh")
	ownh.use_owner_heading = true
	ownh.initial_heading = 90
	lc_start(&f)

	clear_gaps :: proc(s: ^sim.State) {
		s.unported, s.gap_count = 0, 0
	}
	for kind in ([]string{"air ", "spec", "grnd"}) {
		lc_unit(&f, "pkup").pickup_type = sim.res_id(kind)
		clear_gaps(f.s)
		lc_spawn(t, &f, "pkup")
		testing.expectf(t, f.s.unported == 0x41377e, "a %q pickup: unported %x", kind, f.s.unported)
	}

	clear_gaps(f.s)
	if e, _, ok := lc_spawn(t, &f, "brst"); ok {
		testing.expect_value(t, f.s.unported, sim.Site(0x41c9a0))
		testing.expect_value(t, e.vel, sim.Vec{})
	}

	clear_gaps(f.s)
	if e, _, ok := lc_spawn(t, &f, "ownh"); ok {
		testing.expect_value(t, f.s.unported, sim.Site(0))
		testing.expect_value(t, e.heading, 90)
	}
	_, owner, ok := lc_spawn(t, &f, "base")
	if !ok {
		return
	}
	clear_gaps(f.s)
	lc_spawn(t, &f, "ownh", owner = owner)
	testing.expect_value(t, f.s.unported, sim.Site(0x41ca5c))
}

// ChangeState to "Destroy" changes nothing and asks for destruction, which
// G_EG_Process carries out (entity_carry_on): destroyed, by no player, and
// the entity's step ends. "Delete" only marks it.
@(test)
change_state_to_destroy_is_carried_out_as_destruction :: proc(t: ^testing.T) {
	f: Lc_Fixture
	defer vmem.arena_destroy(&f.arena)
	context.allocator = lc_begin(t, &f)
	lc_units(&f, "blow")
	lc_start(&f)

	e, _, ok := lc_spawn(t, &f, "blow")
	d, _, ok2 := lc_spawn(t, &f, "blow")
	if !ok || !ok2 {
		return
	}
	time := lc_time(&f)
	del, des := lifecycle.change_state(f.s, e, false, "Destroy", time)
	testing.expect(t, !del && des)
	testing.expect_value(t, e.state, 0)
	f.events.count = 0
	testing.expect(t, !lifecycle.entity_carry_on(f.s, e, del, des, time), "the step ends")
	testing.expect(t, e.deleted && e.destroyed)
	testing.expect_value(t, e.target_player, -1)
	ev := sim.event_log_entries(&f.events)
	testing.expect(t, len(ev) == 1 && ev[0].kind == .Destroy && ev[0].number == e.number)

	del, des = lifecycle.change_state(f.s, d, false, "Delete", time)
	testing.expect(t, del && !des)
	testing.expect(t, !lifecycle.entity_carry_on(f.s, d, del, des, time))
	testing.expect(t, d.deleted && !d.destroyed)
}

// A state's onCounter fires on the entry that reaches it: to "Destroy" it
// asks for destruction; to another state it resets its own count and enters
// that one, whose own counter may in turn ask for deletion, which the first
// call returns.
@(test)
state_counter_can_chain_into_delete_or_destroy :: proc(t: ^testing.T) {
	f: Lc_Fixture
	defer vmem.arena_destroy(&f.arena)
	context.allocator = lc_begin(t, &f)
	lc_units(&f, "cntr")
	u := lc_unit(&f, "cntr")
	lc_states(u, "Idle", "Hit", "A", "B")
	u.states[1].on_counter, u.states[1].on_counter_change_to = 2, "Destroy"
	u.states[2].on_counter, u.states[2].on_counter_change_to = 1, "B"
	u.states[3].on_counter, u.states[3].on_counter_change_to = 1, "Delete"
	lc_start(&f)

	e, _, ok := lc_spawn(t, &f, "cntr")
	if !ok {
		return
	}
	time := lc_time(&f)
	del, des := lifecycle.change_state(f.s, e, false, "Hit", time)
	testing.expect(t, !del && !des, "the first hit is counted")
	del, des = lifecycle.change_state(f.s, e, false, "Hit", time)
	testing.expect(t, !del && des, "the second reaches the counter")

	del, des = lifecycle.change_state(f.s, e, false, "A", time)
	testing.expect(t, del && !des, "B's counter deletes, through A's")
	testing.expect_value(t, e.state, 3)
	testing.expect_value(t, e.entry_counts[2], 0)
	testing.expect_value(t, e.entry_counts[3], 1)
}

// Priv_CheckSpawningAbilityAtStateChange: a spawn set naming no unit is
// inactive and stamped with the time, and clears the rotation pause. The
// sets are read in order, so the last one read decides the pause.
@(test)
spawn_set_naming_no_unit_is_inactive :: proc(t: ^testing.T) {
	f: Lc_Fixture
	defer vmem.arena_destroy(&f.arena)
	context.allocator = lc_begin(t, &f)
	lc_units(&f, "gun1", "gun2", "shot")
	real := sim.Spawn_Set_Def {
		spawn                                 = sim.res_id("shot"),
		rate_min                              = 5,
		rate_max                              = 5,
		num_in_volley_min                     = 2,
		num_in_volley_max                     = 2,
		delay_between_entities_min            = 3,
		delay_between_entities_max            = 3,
		time_to_pause_rotation_after_spawning = 7,
	}
	empty := sim.Spawn_Set_Def{spawn = sim.NONE, rate_min = 5, rate_max = 5, time_to_pause_rotation_after_spawning = 9}
	sets1 := make([]sim.Spawn_Set_Def, 2)
	sets1[0], sets1[1] = real, empty
	sets2 := make([]sim.Spawn_Set_Def, 2)
	sets2[0], sets2[1] = empty, real
	lc_unit(&f, "gun1").states[0].spawn_sets = sets1
	lc_unit(&f, "gun2").states[0].spawn_sets = sets2
	lc_start(&f)

	g1, _, ok1 := lc_spawn(t, &f, "gun1")
	g2, _, ok2 := lc_spawn(t, &f, "gun2")
	if !ok1 || !ok2 {
		return
	}
	testing.expect(t, g1.has_spawn_info && g1.spawning)
	on, off := g1.spawn_info[0], g1.spawn_info[1]
	testing.expect(t, on.active && on.delay == 5 && on.volley == 2 && on.left == 2 && on.gap == 3)
	testing.expect(t, !off.active && off.delay == 0 && off.last == lc_time(&f))
	testing.expect_value(t, g1.spawn_pause, 0)
	testing.expect(t, !g2.spawn_info[0].active && g2.spawn_info[1].active)
	testing.expect_value(t, g2.spawn_pause, 7)
}

// ChangeState's initial scale: initialScalePercent plus a draw within its
// tolerance, never below 0.
@(test)
initial_scale_tolerance_never_goes_below_zero :: proc(t: ^testing.T) {
	f: Lc_Fixture
	defer vmem.arena_destroy(&f.arena)
	context.allocator = lc_begin(t, &f)
	lc_units(&f, "grow")
	g := lc_unit(&f, "grow")
	g.initial_scale_percent, g.initial_scale_percent_tolerance = 0, 20
	lc_start(&f)

	for c in ([][2]f32{{-4, 0}, {6, 0.06}}) {
		// RandomInt(-10, 10) at 0x4138f4 is the spawn's first draw.
		lc_rig(&f, -10, 10, i32(c[0]))
		if e, _, ok := lc_spawn(t, &f, "grow"); ok {
			testing.expectf(t, e.scale == c[1], "a roll of %v: scale %v, want %v", c[0], e.scale, c[1])
		}
	}
}

// G_Entity::Animate on a looping state that animates backwards: it enters
// the state running backwards, and turns round at each end of its frames
// (to the second, or the second from last) instead of jumping back.
@(test)
ping_pong_animation_turns_at_both_ends :: proc(t: ^testing.T) {
	f: Lc_Fixture
	defer vmem.arena_destroy(&f.arena)
	context.allocator = lc_begin(t, &f)
	lc_units(&f, "flap")
	st := &lc_unit(&f, "flap").states[0]
	st.sprite_face = sim.res_id("flap")
	st.frames_per_direction = 4
	st.frame_delta = 1
	st.do_loop_animation, st.do_animate_backwards = true, true
	sprites := make([]sim.Sprite, 1)
	sprites[0] = {id = sim.res_id("flap"), frames = make([]sim.Sprite_Frame, 4)}
	for &fr in sprites[0].frames {
		fr = {8, 8}
	}
	f.defs.sprites = sprites
	lc_start(&f)

	e, _, ok := lc_spawn(t, &f, "flap")
	if !ok {
		return
	}
	testing.expect(t, e.animating && e.anim_backwards)
	testing.expect_value(t, e.frame, 0)
	want := [?]i32{1, 2, 3, 2, 1, 0, 1, 2}
	got: [len(want)]i32
	time := lc_time(&f)
	for &g in got {
		time += 1
		lifecycle.entity_animate(f.s, e, time)
		g = e.frame
	}
	testing.expect_value(t, got, want)
}

// A part whose state has destroyOwnerOnDestruction takes its owner with it
// when the sweep removes it, credited to the same player; an owner already
// deleted is left as it is.
@(test)
destroyed_part_destroys_its_owner_at_the_sweep :: proc(t: ^testing.T) {
	f: Lc_Fixture
	defer vmem.arena_destroy(&f.arena)
	context.allocator = lc_begin(t, &f)
	lc_units(&f, "base", "turt")
	lc_unit(&f, "turt").states[0].destroy_owner_on_destruction = true
	lc_start(&f)

	base, bref, ok := lc_spawn(t, &f, "base")
	if !ok {
		return
	}
	turret, _, ok2 := lc_spawn(t, &f, "turt", owner = bref)
	if !ok2 {
		return
	}
	lifecycle.entity_destroy(f.s, turret, 0, lc_time(&f))
	testing.expect(t, !base.deleted, "not until the sweep")
	lifecycle.sweep_deleted(f.s)
	testing.expect(t, base.deleted && base.destroyed)
	testing.expect_value(t, base.target_player, 0)
	lifecycle.sweep_deleted(f.s)
	testing.expect(t, !sim.single(f.s, sim.Pool).entity_used[bref.index], "the owner is swept next")

	base2, bref2, ok3 := lc_spawn(t, &f, "base")
	if !ok3 {
		return
	}
	turret2, _, ok4 := lc_spawn(t, &f, "turt", owner = bref2)
	if !ok4 {
		return
	}
	lifecycle.entity_delete(base2)
	lifecycle.entity_destroy(f.s, turret2, 0, lc_time(&f))
	f.events.count = 0
	lifecycle.sweep_deleted(f.s)
	for ev in sim.event_log_entries(&f.events) {
		testing.expect(t, ev.kind != .Destroy, "a deleted owner is not destroyed")
	}
}

// At the sweep, an entity deleted (not destroyed) leaves its deletionSpawn,
// where it was and owned by it.
@(test)
deleted_entity_leaves_its_deletion_spawn :: proc(t: ^testing.T) {
	f: Lc_Fixture
	defer vmem.arena_destroy(&f.arena)
	context.allocator = lc_begin(t, &f)
	lc_units(&f, "flar", "puff")
	lc_unit(&f, "flar").deletion_spawn = sim.res_id("puff")
	lc_start(&f)

	gone, _, ok := lc_spawn(t, &f, "flar", {120, 80})
	shot, _, ok2 := lc_spawn(t, &f, "flar", {300, 40})
	if !ok || !ok2 {
		return
	}
	number := gone.number
	lifecycle.entity_delete(gone)
	lifecycle.entity_destroy(f.s, shot, 0, lc_time(&f))
	f.events.count = 0
	lifecycle.sweep_deleted(f.s)
	testing.expect_value(t, lc_spawn_requests(&f, sim.res_id("puff")), 1)
	n, puff := lc_live(&f, "puff")
	if testing.expect_value(t, n, 1) {
		testing.expect_value(t, puff.loc, sim.Vec{120, 80})
		testing.expect_value(t, puff.owner.number, number)
	}
}

// A unit whose first state is Delete (or Destroy) is a gap in the port: the
// spawn records it, and the entity is deleted at once, in its first state,
// rather than left in no state at all for the next step to trip over.
@(test)
a_first_state_of_delete_is_a_gap_that_deletes :: proc(t: ^testing.T) {
	f: Lc_Fixture
	defer vmem.arena_destroy(&f.arena)
	context.allocator = lc_begin(t, &f)
	lc_units(&f, "gone")
	lc_unit(&f, "gone").states[0].name = "Delete"
	lc_start(&f)
	f.s.unported, f.s.gap_count = 0, 0
	req := sim.spawn_request(sim.res_id("gone"))
	req.loc = {200, 100}
	r := lifecycle.eg_request_spawn(f.s, req)
	testing.expect_value(t, f.s.unported, sim.Site(0x41ab1c))
	e := sim.entity_at(f.s, r.index)
	testing.expect(t, e.deleted, "the entity must be deleted")
	testing.expect_value(t, e.state, 0)
	for _ in 0 ..< 3 {
		sim.step(f.s, {})
	}
	n, _ := lc_live(&f, "gone")
	testing.expect_value(t, n, 0)
}
