package tests

import "core:log"
import "core:os"
import "core:testing"
import vmem "core:mem/virtual"

import "dr:data"
import "dr:plugins/passives"
import "dr:sim"
import "dr:sim/lifecycle"
import "dr:sim/systems/collision_system"
import "dr:sim/systems/player_system"

// What a hit does and what happens to a player (sim/systems/collision_system
// and player_system): G_Entity::Hit, G_Player::Hit and its kin, the
// multiplier, pickups, the power-up overload, and the paths of G_Player::
// Process that play rarely reaches. Against the shipped content, so each is
// skipped without the assets tree. Where no shipped unit takes a path, the
// test edits its own copy of a definition and says so.

@(private = "file")
Hit_Fixture :: struct {
	arena: vmem.Arena,
	defs:  sim.Defs,
	s:     ^sim.State,
}

// Stage 1 in a single-player game, once the ship is in play. `edit`, when
// given, changes the loaded definitions before the session starts, so the
// prefabs built from them see the change.
@(private = "file")
hit_fixture :: proc(t: ^testing.T, f: ^Hit_Fixture, mods := sim.Mods{}, edit: proc(d: ^sim.Defs) = nil) -> bool {
	if !os.exists("assets/data/index.json") {
		log.info("skipped: needs the extracted assets tree")
		return false
	}
	testing.expect(t, vmem.arena_init_growing(&f.arena) == nil)
	alloc := vmem.arena_allocator(&f.arena)
	f.defs, _ = data.assets_defs_load("assets", alloc)
	if edit != nil {
		edit(&f.defs)
	}
	f.s = new(sim.State, alloc)
	context.allocator = alloc
	sim.init(f.s, sim.Session{seed = 1, level_id = f.defs.levels[0].id, game_type = .Single, mods = mods}, &f.defs)
	for i := 0; i < 300 && sim.player_at(f.s, 0).state != .Playing; i += 1 {
		sim.session_step(f.s, {})
	}
	return testing.expect(t, sim.player_at(f.s, 0).state == .Playing, "the ship must be in play")
}

// A stationary unit at `loc`, there at once (no appear delay).
@(private = "file")
hit_spawn :: proc(t: ^testing.T, s: ^sim.State, id: string, loc: sim.Vec, owner := sim.NO_REF) -> (sim.Entity, sim.Entity_Ref) {
	req := sim.spawn_request(sim.res_id(id))
	req.loc = loc
	req.stationary = true
	req.owner = owner
	r := lifecycle.eg_request_spawn(s, req)
	if !testing.expectf(t, sim.ref_valid(s, r), "%s must spawn", id) {
		return {}, r
	}
	e := sim.entity_at(s, r.index)
	e.loc = loc // some units spawn at a random offset
	e.appear_delay = 0
	return e, r
}

// Gives the entity a component of its own. Its row moves, and with it
// others in its table, so every view found before is found again from its
// index afterwards.
@(private = "file")
hit_give :: proc(s: ^sim.State, r: sim.Entity_Ref, c: $T) {
	sim.add(s.ecs, sim.pool_entity(r.index), c)
}

// The live entity with this unique number, if there is one.
@(private = "file")
hit_find :: proc(s: ^sim.State, number: i32) -> (sim.Entity, bool) {
	for used, i in sim.single(s, sim.Pool).entity_used {
		if e := sim.entity_at(s, i32(i)); used && !e.deleted && e.number == number {
			return e, true
		}
	}
	return {}, false
}

@(private = "file")
hit_count :: proc(s: ^sim.State, id: sim.Res_ID) -> (n: int) {
	ui := sim.unit_index(s.defs, id)
	for used, i in sim.single(s, sim.Pool).entity_used {
		if e := sim.entity_at(s, i32(i)); used && !e.deleted && e.unit == i32(ui) {
			n += 1
		}
	}
	return
}

@(private = "file")
hit_now :: proc(s: ^sim.State) -> i32 {
	return sim.single(s, sim.Clock).time
}

// G_Player::Shields_IncreasePercentage: the change is kept within 0..100,
// and a player out of the game, or a change of nothing, is left alone.
@(test)
shield_changes_stay_within_0_and_100 :: proc(t: ^testing.T) {
	f: Hit_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !hit_fixture(t, &f) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	p := sim.player_at(s, 0)
	collision_system.shields_set(p, 50)
	collision_system.player_shields_add(s, p, 0)
	testing.expect_value(t, p.shields, f32(50))
	collision_system.player_shields_add(s, p, -80)
	testing.expect_value(t, p.shields, f32(0))
	collision_system.player_shields_add(s, p, 30)
	testing.expect_value(t, p.shields, f32(30))
	collision_system.player_shields_add(s, p, 200)
	testing.expect_value(t, p.shields, f32(100))

	// Player 2 sits out a single-player game with no shields at all.
	p2 := sim.player_at(s, 1)
	testing.expect(t, !p2.active)
	collision_system.player_shields_add(s, p2, 30)
	testing.expect_value(t, p2.shields, f32(0))
}

// G_Player::Score_Adjust: a flat bonus is not multiplied and, however far
// it takes the score, never earns a life -- it moves the next step instead;
// a multiplied score past the threshold does earn one. G_Player::Lives_Add
// gives nothing to a player out of the game.
@(test)
flat_score_skips_the_multiplier_and_the_extra_life :: proc(t: ^testing.T) {
	f: Hit_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !hit_fixture(t, &f) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	p := sim.player_at(s, 0)
	step := sim.trunc_i32(s.defs.perm_floats[0xb6])
	p.multiplier = 3
	p.score = 0
	p.next_life_score = 10
	lives := p.lives
	collision_system.player_score(s, p, 1000, true)
	testing.expect_value(t, p.score, i32(1000))
	testing.expect_value(t, p.lives, lives)
	testing.expect_value(t, p.life_step, step + 1000)
	collision_system.player_score(s, p, 100, false)
	testing.expect_value(t, p.score, i32(1300))
	testing.expect_value(t, p.lives, lives + 1)

	p2 := sim.player_at(s, 1)
	lives2 := p2.lives
	collision_system.player_add_life(s, p2, true)
	testing.expect_value(t, p2.lives, lives2)
}

// G_Player::Multiplier_Advance and Priv_Multiplier_SpawnForCurrentMultiplier:
// x1 to x5 one at a time, then x10, and no further; each step replaces the
// icon with the one for the new multiplier (perm objects 0x23..0x27).
@(test)
multiplier_climbs_to_x10_with_an_icon_for_each :: proc(t: ^testing.T) {
	f: Hit_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !hit_fixture(t, &f) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	p := sim.player_at(s, 0)
	testing.expect_value(t, p.multiplier, i32(1))
	want := [5]i32{2, 3, 4, 5, 10}
	prev := p.multiplier_entity
	for m, k in want {
		collision_system.player_multiplier_advance(s, p)
		testing.expect_value(t, p.multiplier, m)
		icon, ok := hit_find(s, p.multiplier_entity)
		if !testing.expectf(t, ok, "no icon for x%d", m) {
			return
		}
		unit := sim.unit_index(s.defs, s.defs.perm_objects[0x23 + k])
		testing.expectf(t, icon.unit == i32(unit), "x%d shows unit %d, not %d", m, icon.unit, unit)
		if _, still := hit_find(s, prev); k > 0 && still {
			testing.expectf(t, false, "the icon before x%d must go", m)
		}
		prev = p.multiplier_entity
	}
	// At x10 there is nowhere further to go: the same icon stays.
	collision_system.player_multiplier_advance(s, p)
	testing.expect_value(t, p.multiplier, i32(10))
	testing.expect_value(t, p.multiplier_entity, prev)
	_, ok := hit_find(s, prev)
	testing.expect(t, ok)
}

// Neither advancing nor showing the multiplier happens to a player out of
// play; and with no icon defined for x4 (this test's own definitions have
// perm object 0x25 cleared, which the shipped ones do not), reaching x4
// leaves the x3 icon up rather than taking it away.
@(test)
multiplier_needs_a_player_in_play_and_an_icon :: proc(t: ^testing.T) {
	f: Hit_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !hit_fixture(t, &f) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	p := sim.player_at(s, 0)
	next := sim.single(s, sim.Pool).next_entity
	p.state = .Dying
	collision_system.player_multiplier_advance(s, p)
	testing.expect_value(t, p.multiplier, i32(1))
	p.multiplier = 2
	collision_system.player_multiplier_spawn(s, p)
	testing.expect_value(t, p.multiplier_entity, i32(-1))
	testing.expect_value(t, sim.single(s, sim.Pool).next_entity, next)

	p.state = .Playing
	p.multiplier = 2
	f.defs.perm_objects[0x25] = sim.NONE
	collision_system.player_multiplier_advance(s, p)
	x3 := p.multiplier_entity
	collision_system.player_multiplier_advance(s, p)
	testing.expect_value(t, p.multiplier, i32(4))
	testing.expect_value(t, p.multiplier_entity, x3)
	_, ok := hit_find(s, x3)
	testing.expect(t, ok, "the x3 icon stays up")
}

// G_Player::Destroy: the money spills as coins, largest first (67 is one
// 50, one 10, one 5 and two 1s), and a death takes the multiplier back to
// x1 and its icon away.
@(test)
player_death_spills_coins_and_loses_the_multiplier :: proc(t: ^testing.T) {
	f: Hit_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !hit_fixture(t, &f) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	p := sim.player_at(s, 0)
	collision_system.player_multiplier_advance(s, p)
	collision_system.player_multiplier_advance(s, p)
	icon := p.multiplier_entity
	if _, ok := hit_find(s, icon); !testing.expect(t, ok) {
		return
	}
	coins: [4]int
	for &n, i in coins {
		n = hit_count(s, s.defs.perm_objects[2 + i])
	}
	p.money = 67
	collision_system.player_destroy(s, p, hit_now(s))
	testing.expect_value(t, p.multiplier, i32(1))
	_, ok := hit_find(s, icon)
	testing.expect(t, !ok, "the multiplier icon must go")
	for want, i in ([4]int{1, 1, 1, 2}) {
		testing.expect_value(t, hit_count(s, s.defs.perm_objects[2 + i]) - coins[i], want)
	}
	testing.expect_value(t, p.money, i32(0))
	testing.expect_value(t, p.state, sim.Player_State.Dying)
	testing.expect(t, p.invulnerable)
}

// FUN_0041c1b0: an invulnerable player passes over a weapon pickup, which
// stays; otherwise touching it consumes it (the weapon only changes on
// Change_Air). A "spec" pickup is consumed and does nothing else. No
// shipped pickup is either kind, so this test's own shield pickup (pish)
// is retyped.
@(test)
weapon_pickups_wait_for_a_vulnerable_player :: proc(t: ^testing.T) {
	f: Hit_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !hit_fixture(t, &f) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	p := sim.player_at(s, 0)
	u := &f.defs.units[sim.unit_index(&f.defs, sim.res_id("pish"))]
	u.pickup_type = sim.res_id("air ")
	e, _ := hit_spawn(t, s, "pish", p.loc)
	if e.obj == nil {
		return
	}
	touch :: proc(s: ^sim.State, e: sim.Entity) -> bool {
		es := sim.entity_step(s, e, sim.single(s, sim.Clock).time)
		es.bounds = lifecycle.object_bounds(e.obj)
		return collision_system.player_contact_stage(s, e, &es)
	}
	air := p.weapons.air.weapon
	p.invulnerable = true
	testing.expect(t, touch(s, e), "an invulnerable player leaves it")
	testing.expect(t, !e.deleted)
	p.invulnerable = false
	testing.expect(t, !touch(s, e), "a vulnerable player takes it")
	testing.expect(t, e.deleted && e.killed_by_player)
	testing.expect_value(t, p.weapons.air.weapon, air)

	u.pickup_type = sim.res_id("spec")
	spec, _ := hit_spawn(t, s, "pish", p.loc)
	if spec.obj == nil {
		return
	}
	shields, money, lives, mult := p.shields, p.money, p.lives, p.multiplier
	testing.expect(t, collision_system.player_collect(s, p, spec))
	testing.expect(t, p.shields == shields && p.money == money && p.lives == lives && p.multiplier == mult)
}

// G_Player::PowerupOverload_Process: the overload is called off when the
// player leaves play or the level is ending.
@(test)
overload_ends_out_of_play_and_at_level_end :: proc(t: ^testing.T) {
	f: Hit_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !hit_fixture(t, &f) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	p := sim.player_at(s, 0)
	now := hit_now(s)
	collision_system.player_overload_begin(s, p, now)
	sim.single(s, sim.Level_Info).ending = true
	collision_system.player_overload_process(s, p, now + 1)
	testing.expect(t, !p.overloaded, "the level end calls it off")
	testing.expect_value(t, p.tint_color, u16(0x7fff))
	sim.single(s, sim.Level_Info).ending = false

	collision_system.player_overload_begin(s, p, now)
	p.state = .Dying
	collision_system.player_overload_process(s, p, now + 1)
	testing.expect(t, !p.overloaded, "leaving play calls it off")
	testing.expect_value(t, p.overload_warnings, i32(0))
}

// Held too long, the overload flashes and warns
// powerupOverload_NumWarnings times, and on the last warning the player is
// destroyed; the overload is then called off.
@(test)
overload_destroys_the_player_on_the_last_warning :: proc(t: ^testing.T) {
	f: Hit_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !hit_fixture(t, &f) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	p := sim.player_at(s, 0)
	d := sim.player_def(s, p)
	if !testing.expect(t, d.powerup_overload_num_warnings > 1) {
		return
	}
	now := hit_now(s)
	collision_system.player_overload_begin(s, p, now)
	for i := 0; i < 10000 && p.state == .Playing; i += 1 {
		now += 1
		warned := p.overload_warnings
		collision_system.player_overload_process(s, p, now)
		if p.state == .Playing && p.overload_warnings > warned {
			testing.expect_value(t, p.tint, f32(100)) // each warning flashes full
		}
	}
	testing.expect_value(t, p.state, sim.Player_State.Dying)
	testing.expect_value(t, p.overload_warnings, d.powerup_overload_num_warnings)
	testing.expect_value(t, p.overload_interval, max(d.powerup_overload_initial_time_between_warnings - d.powerup_overload_num_warnings, d.powerup_overload_minimum_time_between_warnings))
	collision_system.player_overload_process(s, p, now + 1)
	testing.expect(t, !p.overloaded)
}

// G_Entity::Hit does nothing to an entity already deleted, and an entity
// with no shields left deals and takes nothing more: it is not destroyed
// again, nor scored again.
@(test)
entity_hit_spares_deleted_and_spent_entities :: proc(t: ^testing.T) {
	f: Hit_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !hit_fixture(t, &f) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	p := sim.player_at(s, 0)
	score := p.score
	gone, _ := hit_spawn(t, s, "mine", {100, 100})
	spent, _ := hit_spawn(t, s, "mine", {300, 100})
	if gone.obj == nil || spent.obj == nil {
		return
	}
	gone.deleted = true
	testing.expect_value(t, collision_system.entity_hit(s, gone, 5, 0, hit_now(s)), f32(0))
	testing.expect_value(t, gone.shields, f32(10))
	spent.shields = 0
	testing.expect_value(t, collision_system.entity_hit(s, spent, 5, 0, hit_now(s)), f32(0))
	testing.expect(t, !spent.deleted)
	testing.expect_value(t, p.score, score)
}

// G_Entity::Priv_ChangeStateOnShieldDepletion: a unit with a state flagged
// for shield depletion goes into it instead of being destroyed, and the
// player still scores it. No shipped unit has one; this test flags the
// mine's second state ("Retreat & Shrink") in its own definitions.
@(test)
spent_shields_change_state_when_the_unit_asks :: proc(t: ^testing.T) {
	f: Hit_Fixture
	defer vmem.arena_destroy(&f.arena)
	flag :: proc(d: ^sim.Defs) {
		d.units[sim.unit_index(d, sim.res_id("mine"))].states[1].use_this_state_on_shield_depletion = true
	}
	if !hit_fixture(t, &f, edit = flag) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	p := sim.player_at(s, 0)
	e, _ := hit_spawn(t, s, "mine", {200, 100})
	if e.obj == nil {
		return
	}
	testing.expect(t, e.has_depletion_state)
	testing.expect_value(t, e.state, i32(0))
	score := p.score
	testing.expect_value(t, collision_system.entity_hit(s, e, 25, 0, hit_now(s)), f32(10))
	testing.expect(t, !e.deleted, "a depletion state stands in for destruction")
	testing.expect_value(t, e.state, i32(1))
	testing.expect_value(t, sim.state_of(s, e).name, "Retreat & Shrink")
	testing.expect_value(t, p.score, score + sim.unit_of(s, e).score * p.multiplier)
}

// FUN_0041b920's hit half with statePassHitsToOwner: a shot that passes its
// hits on sends the target's damage to its owner and is untouched; and a
// target that passes its hits on sends the shot's damage to the *shot's*
// owner, not its own -- the original's slip, kept. The component is given
// to the entities directly: no shipped shot or mine has it. The shot is a
// Bacta Gun bullet (0.6 damage) with a mine as its owner; the target is a
// mine (2 damage).
@(test)
passed_hits_land_on_the_shots_owner :: proc(t: ^testing.T) {
	f: Hit_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !hit_fixture(t, &f) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	near :: proc(a, b: f32) -> bool {return abs(a - b) < 1e-4}

	// The target passes hits on.
	{
		_, oref := hit_spawn(t, s, "mine", {60, 60})
		_, tref := hit_spawn(t, s, "mine", {200, 200})
		_, sref := hit_spawn(t, s, "bagb", {200, 200}, oref)
		if !sim.ref_valid(s, oref) || !sim.ref_valid(s, tref) || !sim.ref_valid(s, sref) {
			return
		}
		hit_give(s, tref, collision_system.Passes_Hits_To_Owner{})
		owner, target, shot := sim.entity_at(s, oref.index), sim.entity_at(s, tref.index), sim.entity_at(s, sref.index)
		owner.shields = 500
		collision_system.collide_entities(s, shot, target, hit_now(s))
		testing.expectf(t, near(owner.shields, 499.4), "the shot's owner takes the shot's 0.6, has %v", owner.shields)
		testing.expect_value(t, target.shields, f32(10))
		testing.expect(t, shot.deleted, "the shot takes the mine's hit itself")
	}
	// The shot passes hits on.
	{
		_, oref := hit_spawn(t, s, "mine", {60, 300})
		_, tref := hit_spawn(t, s, "mine", {300, 300})
		_, sref := hit_spawn(t, s, "bagb", {300, 300}, oref)
		if !sim.ref_valid(s, oref) || !sim.ref_valid(s, tref) || !sim.ref_valid(s, sref) {
			return
		}
		hit_give(s, sref, collision_system.Passes_Hits_To_Owner{})
		owner, target, shot := sim.entity_at(s, oref.index), sim.entity_at(s, tref.index), sim.entity_at(s, sref.index)
		owner.shields = 500
		collision_system.collide_entities(s, shot, target, hit_now(s))
		testing.expectf(t, near(owner.shields, 498), "the owner takes the mine's 2, has %v", owner.shields)
		testing.expect(t, !shot.deleted && near(shot.shields, 0.6), "the shot is untouched")
		testing.expectf(t, near(target.shields, 9.4), "the target takes the shot's 0.6, has %v", target.shields)
	}
}

// Touching a player, an entity whose state passes hits on sends the
// collision's damage (perm float 0xa1) to its owner and takes none itself;
// the player is hit as usual. Given the component directly, as above.
@(test)
touching_a_player_hurts_the_owner_of_a_passing_entity :: proc(t: ^testing.T) {
	f: Hit_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !hit_fixture(t, &f) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	p := sim.player_at(s, 0)
	_, oref := hit_spawn(t, s, "mine", {60, 60})
	_, cref := hit_spawn(t, s, "mine", p.loc, oref)
	if !sim.ref_valid(s, oref) || !sim.ref_valid(s, cref) {
		return
	}
	hit_give(s, cref, collision_system.Passes_Hits_To_Owner{})
	owner, child := sim.entity_at(s, oref.index), sim.entity_at(s, cref.index)
	owner.shields = 500
	p.hit_time = -10000
	es := sim.entity_step(s, child, hit_now(s))
	es.bounds = lifecycle.object_bounds(child.obj)
	testing.expect(t, collision_system.player_contact_stage(s, child, &es))
	testing.expect_value(t, owner.shields, 500 - s.defs.perm_floats[0xa1])
	testing.expect_value(t, child.shields, f32(10))
	testing.expect_value(t, p.hit_time, hit_now(s))
	testing.expect(t, p.shields < 100, "the player is hit")
}

// A shot that is not a player's hits only player shots, and only those on
// screen: one wholly above the top edge is passed over. The Player
// Explosion Ring (pler) is such a shot. The shots it may hit are player
// shots that can be hit and are not themselves harmless to players, which
// no shipped unit is; so this test's definitions make the Bacta Gun bullet
// one, and give the ring 1 damage (it has none).
@(test)
a_shot_passes_over_player_shots_above_the_screen :: proc(t: ^testing.T) {
	f: Hit_Fixture
	defer vmem.arena_destroy(&f.arena)
	hittable :: proc(d: ^sim.Defs) {
		bullet := &d.units[sim.unit_index(d, sim.res_id("bagb"))]
		bullet.can_be_hit_by_player_projectile = true
		bullet.harmless_to_players = false
		d.units[sim.unit_index(d, sim.res_id("pler"))].damage = 1
	}
	if !hit_fixture(t, &f, edit = hittable) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	for y in ([2]f32{200, -30}) {
		ring, _ := hit_spawn(t, s, "pler", {100, y})
		shot, _ := hit_spawn(t, s, "bagb", {100, y})
		if ring.obj == nil || shot.obj == nil {
			return
		}
		shot.shields = 5
		es := sim.entity_step(s, ring, hit_now(s))
		collision_system.entity_collisions(s, ring, &es)
		on_screen := lifecycle.object_bounds(shot.obj).bottom >= 0
		testing.expectf(t, (shot.shields == 4) == on_screen, "at y %v the player shot has %v shields", y, shot.shields)
		ring.deleted, shot.deleted = true, true
	}
}

// G_Player::Priv_Appear and Priv_ProcessState act only on a player in the
// game: player 2 of a single-player game is never brought in.
@(test)
a_player_out_of_the_game_never_appears :: proc(t: ^testing.T) {
	f: Hit_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !hit_fixture(t, &f) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	p2 := sim.player_at(s, 1)
	testing.expect(t, !p2.active)
	state := p2.state
	next := sim.single(s, sim.Pool).next_entity
	player_system.player_appear(s, p2, hit_now(s))
	player_system.player_process_state(s, p2, hit_now(s) + 100000)
	testing.expect_value(t, p2.state, state)
	testing.expect(t, !p2.appeared)
	testing.expect_value(t, sim.single(s, sim.Pool).next_entity, next)
}

// The weapons fire only at full size: a ship still scaling in holds its
// fire.
@(test)
a_scaled_ship_holds_its_fire :: proc(t: ^testing.T) {
	f: Hit_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !hit_fixture(t, &f) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	p := sim.player_at(s, 0)
	ps := sim.Player_Step{time = hit_now(s)}
	p.inputs = {.Fire_Air}
	next := sim.single(s, sim.Pool).next_entity
	p.scale = 0.5
	testing.expect(t, player_system.fire_stage(s, p, &ps))
	testing.expect_value(t, sim.single(s, sim.Pool).next_entity, next)
	testing.expect(t, !p.weapons.prev_air, "the press is not even seen")
	p.scale = 1
	player_system.fire_stage(s, p, &ps)
	testing.expect(t, sim.single(s, sim.Pool).next_entity > next, "at full size it fires")
}

// With Fires_Backwards (the plasma bomb's passive), the crosshair drops
// behind the ship at half the reach, kept on screen at the bottom, and is
// pushed out by holding Up against the top of the screen, not Down against
// the bottom.
@(test)
a_backwards_crosshair_sits_behind_the_ship :: proc(t: ^testing.T) {
	f: Hit_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !hit_fixture(t, &f, session_mods(true, false)) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	p := sim.player_at(s, 0)
	bomb := i32(-1)
	for &w, i in f.defs.weapons {
		if w.id == passives.WEAPON_PLASMA_BOMB {
			bomb = i32(i)
		}
	}
	if !testing.expect(t, bomb >= 0, "no Plasma Bomb in the data") {
		return
	}
	p.weapons.ground.weapon = bomb
	p.weapons.crosshair_shown = true
	passives.levels_of(s, p.number)^[.Ground_Variant_1] = 1
	h := f32(sim.view_height(s.defs))
	half := f32(lifecycle.halve(p.weapons.crosshair.dims.y))
	c := p.weapons.crosshair
	now := hit_now(s)

	// At the bottom, pushing Down does not pull it out; it would be off
	// the bottom of the screen, so it is held on it.
	p.loc.y, p.vel, p.crosshair_reach = h, {}, 0
	p.inputs = {.Down}
	player_system.player_move(s, p, now)
	testing.expect_value(t, p.crosshair_reach, i32(0))
	testing.expect_value(t, c.loc.y, h - half)
	testing.expect(t, c.loc.y > p.loc.y, "behind the ship")

	// At the top, pushing Up pulls it out, behind the ship.
	p.loc.y, p.vel = 0, {}
	p.inputs = {.Up}
	player_system.player_move(s, p, now)
	reach := p.crosshair_reach
	testing.expect_value(t, reach, sim.trunc_i32(s.defs.perm_floats[0xb9]))
	yoff := f32(sim.weapon_def(s, bomb).crosshair_y_offset)
	testing.expect_value(t, c.loc.y, p.loc.y - (f32(reach) + yoff) / 2)
	testing.expect(t, c.loc.y > p.loc.y, "behind the ship")
}
