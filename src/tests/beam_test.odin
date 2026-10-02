package tests

import "core:testing"
import vmem "core:mem/virtual"

import "dr:data"
import "dr:plugins/loadout"
import "dr:plugins/new_weapons"
import "dr:plugins/passives"
import "dr:sim"
import "dr:sim/stats"
import "dr:sim/systems/weapon_system"

// The Discharge Beam (plugins/new_weapons/beam.odin): an instant line that carries its
// leftover damage through what it kills. The design is notes/new-weapons.md;
// these pin how it was read, see docs/new-weapons.md. Against the shipped
// content, so each is skipped without the assets tree.

@(private = "file")
Beam_Fixture :: struct {
	arena: vmem.Arena,
	defs:  sim.Defs,
	s:     ^sim.State,
	db:    i32, // the Discharge Beam's weapon index
}

// Stage 1 in a New Weapons session, once the ship is in play; with easy
// mode's passives too if `easy`.
@(private = "file")
beam_fixture :: proc(t: ^testing.T, f: ^Beam_Fixture, easy := false) -> bool {
	f.defs = assets_defs(t, &f.arena, "plugins/new_weapons/data") or_return
	alloc := vmem.arena_allocator(&f.arena)
	if _, ok := data.extra_defs_load(&f.defs, alloc); !testing.expect(t, ok) {
		return false
	}
	f.db = -1
	for &w, i in f.defs.weapons {
		if w.id == sim.res_id("aidb") {
			f.db = i32(i)
		}
	}
	if !testing.expect(t, f.db >= 0, "no Discharge Beam in plugins/new_weapons") {
		return false
	}
	f.s = new(sim.State, alloc)
	context.allocator = alloc // the state's world goes in the arena too
	return play_start(t, f.s, sim.Session{seed = 1, level_id = f.defs.levels[0].id, game_type = .Single, mods = session_mods(easy, true)}, &f.defs)
}

@(private = "file")
count_unit :: proc(s: ^sim.State, id: sim.Res_ID) -> (n: int) {
	ui := sim.unit_index(s.defs, id)
	for used, i in sim.single(s, sim.Pool).entity_used {
		if e := sim.entity_at(s, i32(i)); used && !e.deleted && e.unit == i32(ui) {
			n += 1
		}
	}
	return
}

@(test)
discharge_beam_loads_as_new_content :: proc(t: ^testing.T) {
	f: Beam_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !beam_fixture(t, &f) {
		return
	}
	w := &f.defs.weapons[f.db]
	testing.expect(t, w.extra && sim.weapon_bool(w, new_weapons.BEAM))
	// A weapon without the plugin's keys, as every original one is, reads
	// each key's default.
	orig := &f.defs.weapons[0]
	testing.expect(t, !orig.extra && !sim.weapon_bool(orig, new_weapons.BEAM))
	testing.expect_value(t, sim.weapon_id(orig, new_weapons.BEAM_MOTE), sim.NONE)
	testing.expect_value(t, new_weapons.beam_windup(orig), 0)
	testing.expect_value(t, sim.weapon_float(orig, new_weapons.BEAM_DAMAGE), 0)
	_, fires := sim.weapon_fire(orig)
	testing.expect(t, !fires, "the plugin fires only its own weapons")
	testing.expect_value(t, w.type, sim.WEP_AIR)
	testing.expect_value(t, w.minimum_level_available, 10)
	testing.expect(t, new_weapons.beam_def(w).damage > 0 && new_weapons.beam_def(w).release_damage > new_weapons.beam_def(w).damage)
	testing.expect(t, new_weapons.beam_def(w).release_width > new_weapons.beam_def(w).width, "a charged beam is wider")
	testing.expect(t, new_weapons.beam_windup(w) > 0, "a pulse winds up")
	b := new_weapons.beam_def(w)
	for id in ([]sim.Res_ID{b.flash, b.mote, b.mote_sounded, w.spawns[0].unit, w.powerup_air_activation_spawn, w.powerup_air_release_spawn}) {
		testing.expectf(t, sim.unit_index(&f.defs, id) >= 0, "unit %v must load", id)
	}
	testing.expect(t, !f.defs.units[sim.unit_index(&f.defs, w.spawns[0].unit)].player_projectile, "the beam itself is not a projectile")
	// A mote is harmless; what it bursts into is a player shot.
	for id in ([]sim.Res_ID{b.mote, b.mote_sounded}) {
		u := &f.defs.units[sim.unit_index(&f.defs, id)]
		testing.expect(t, !u.player_projectile, "a mote is not a shot")
		burst := &u.states[len(u.states) - 1]
		testing.expect_value(t, len(burst.spawn_sets), 3)
		for &set in burst.spawn_sets {
			ci := sim.unit_index(&f.defs, set.spawn)
			testing.expect(t, ci >= 0 && f.defs.units[ci].player_projectile, "a mote bursts into player shots")
		}
	}
	for level in i32(1) ..= 12 {
		testing.expect(t, weapon_system.best_air_weapon(&f.defs, level) != f.db)
	}
}

// Three targets in a column, fired at nearest first whatever order they
// were spawned in: the beam kills the first two and carries what their
// shields left into the third, which stands and stops it. A target beside
// the line is untouched.
@(test)
discharge_beam_carries_leftover_damage :: proc(t: ^testing.T) {
	f: Beam_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !beam_fixture(t, &f) {
		return
	}
	s := f.s
	h := sim.player_at(s, 0).weapons
	wd := &f.defs.weapons[f.db]
	at := sim.Vec{208, 420}
	far := mine_spawn(t, s, at + {0, -240}, 5)
	near := mine_spawn(t, s, at + {0, -80}, 1)
	mid := mine_spawn(t, s, at + {0, -160}, 1)
	aside := mine_spawn(t, s, at + {60, -120}, 1)
	if far.obj == nil || near.obj == nil || mid.obj == nil || aside.obj == nil {
		return
	}
	s.effects.count = 0
	new_weapons.beam_fire(s, h, wd, at, 2.5, new_weapons.beam_def(wd).width, false, sim.single(s, sim.Clock).time)
	testing.expect(t, near.deleted, "the first target must die")
	testing.expect(t, mid.deleted, "the leftover must kill the second")
	testing.expect(t, !far.deleted && abs(far.shields - 4.5) < 1e-4, "the third takes the last 0.5")
	testing.expect(t, !aside.deleted && aside.shields == 1, "off the line is not hit")
	if testing.expect_value(t, len(new_weapons.beam_shots(s)), 1) {
		ev := new_weapons.beam_shots(s)[0]
		testing.expect_value(t, ev.to_y, far.loc.y)
		testing.expect(t, !ev.charged && ev.from.x == at.x && ev.from.y < at.y)
	}
	// Again on the same step: the hit delay protects the third, and the
	// beam stops there without dealing anything.
	new_weapons.beam_fire(s, h, wd, at, 2.5, new_weapons.beam_def(wd).width, false, sim.single(s, sim.Clock).time)
	testing.expect(t, abs(far.shields - 4.5) < 1e-4)
	testing.expect_value(t, new_weapons.beam_shots(s)[1].to_y, far.loc.y)
}

// With nothing to stop it, the beam goes off the top of the screen.
@(test)
discharge_beam_leaves_the_screen :: proc(t: ^testing.T) {
	f: Beam_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !beam_fixture(t, &f) {
		return
	}
	s := f.s
	wd := &f.defs.weapons[f.db]
	one := mine_spawn(t, s, {8, 300}, 0.5)
	if one.obj == nil {
		return
	}
	s.effects.count = 0
	new_weapons.beam_fire(s, sim.player_at(s, 0).weapons, wd, {8, 420}, 2, new_weapons.beam_def(wd).width, false, sim.single(s, sim.Clock).time)
	testing.expect(t, one.deleted)
	testing.expect(t, len(new_weapons.beam_shots(s)) == 1 && new_weapons.beam_shots(s)[0].to_y < 0)
}

// A release deals the charge's damage in one beam, in proportion to the
// level reached against the weapon's own max.
@(test)
discharge_beam_release_scales_with_charge :: proc(t: ^testing.T) {
	f: Beam_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !beam_fixture(t, &f) {
		return
	}
	s := f.s
	h := sim.player_at(s, 0).weapons
	wd := &f.defs.weapons[f.db]
	at := sim.Vec{208, 420}
	top := wd.powerup_air_max_power_level
	wall := mine_spawn(t, s, at + {0, -100}, 100)
	if wall.obj == nil {
		return
	}
	s.effects.count = 0
	new_weapons.beam_release(s, h, wd, at, top, sim.single(s, sim.Clock).time)
	testing.expect(t, abs(100 - wall.shields - new_weapons.beam_def(wd).release_damage) < 1e-3, "a full charge deals the release damage")
	testing.expect(t, len(new_weapons.beam_shots(s)) == 1 && new_weapons.beam_shots(s)[0].charged && new_weapons.beam_shots(s)[0].width == new_weapons.beam_def(wd).release_width)
	wall.last_hit = -100
	before := wall.shields
	new_weapons.beam_release(s, h, wd, at, top / 2, sim.single(s, sim.Clock).time)
	testing.expect(t, abs(before - wall.shields - new_weapons.beam_def(wd).release_damage / 2) < 1e-3, "half a charge deals half")
}

// A charged beam leaves a mote every mote_spacing px from the gun to where
// it stopped, one of them sounded. They burst together, later the fuller
// the charge, into three fragments each.
@(test)
discharge_beam_release_leaves_motes :: proc(t: ^testing.T) {
	f: Beam_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !beam_fixture(t, &f) {
		return
	}
	s := f.s
	h := sim.player_at(s, 0).weapons
	wd := &f.defs.weapons[f.db]
	b := new_weapons.beam_def(wd)
	at := sim.Vec{208, 420}
	top := wd.powerup_air_max_power_level
	wall := mine_spawn(t, s, at + {0, -100}, 100)
	if wall.obj == nil {
		return
	}
	from := new_weapons.beam_origin(wd, at)
	want := 0
	for y := from.y - f32(b.mote_spacing) / 2; y > wall.loc.y; y -= f32(b.mote_spacing) {
		want += 1
	}
	testing.expect(t, want >= 3)
	motes :: proc(s: ^sim.State, b: new_weapons.Beam_Def, out: ^[dynamic]sim.Entity) {
		clear(out)
		for used, i in sim.single(s, sim.Pool).entity_used {
			e := sim.entity_at(s, i32(i))
			if used && !e.deleted && (e.unit == sim.unit_index(s.defs, b.mote) || e.unit == sim.unit_index(s.defs, b.mote_sounded)) {
				append(out, e)
			}
		}
	}
	found := make([dynamic]sim.Entity, context.temp_allocator)
	new_weapons.beam_release(s, h, wd, at, top, sim.single(s, sim.Clock).time)
	motes(s, b, &found)
	testing.expect_value(t, len(found), want)
	testing.expect_value(t, count_unit(s, b.mote_sounded), 1)
	for e in found {
		testing.expect_value(t, e.loc.x, from.x)
		testing.expect(t, e.loc.y < from.y && e.loc.y > wall.loc.y)
		testing.expect_value(t, e.timer, b.mote_delay_max)
	}
	// Half a charge bursts sooner.
	for e in found {
		e.deleted = true
	}
	wall.last_hit = -100
	new_weapons.beam_release(s, h, wd, at, top / 2, sim.single(s, sim.Clock).time)
	motes(s, b, &found)
	if testing.expect_value(t, len(found), want) {
		testing.expect_value(t, found[0].timer, b.mote_delay_min + (b.mote_delay_max - b.mote_delay_min) / 2)
	}
	// Stepped on, each bursts into three fragments.
	frag := f.defs.units[sim.unit_index(&f.defs, b.mote)].states[1].spawn_sets[0].spawn
	seen := make(map[i32]bool, context.temp_allocator)
	fragments := 0
	for _ in 0 ..< b.mote_delay_max {
		sim.session_step(s, {})
		ui := sim.unit_index(s.defs, frag)
		for used, i in sim.single(s, sim.Pool).entity_used {
			e := sim.entity_at(s, i32(i))
			if used && e.unit == ui && !(e.number in seen) {
				seen[e.number] = true
				fragments += 1
			}
		}
	}
	testing.expect_value(t, fragments, 3 * want)
}

// Through the fire button: a press fires a pulse once it has wound up, and
// holding charges it; letting go releases one charged beam.
@(test)
discharge_beam_fires_from_the_button :: proc(t: ^testing.T) {
	f: Beam_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !beam_fixture(t, &f) {
		return
	}
	s := f.s
	p := sim.player_at(s, 0)
	loadout.slots_of(s, 0).loadout[0] = f.db
	weapon_system.change_weapon(s, p.weapons, sim.WEP_AIR, f.db)
	pulses, charged := 0, 0
	for i in 0 ..< 120 {
		sim.session_step(s, {i < 100 ? {.Fire_Air} : {}, {}})
		for ev in new_weapons.beam_shots(s) {
			if ev.charged {
				charged += 1
			} else {
				pulses += 1
			}
		}
	}
	testing.expect_value(t, pulses, 1)
	testing.expect_value(t, charged, 1)
}

// A press fires nothing on its own step: the pulse comes windup steps
// later, and the firing delay counts from the pulse, so tapping as fast as
// the button allows fires once every windup + delay + 1 steps.
@(test)
discharge_beam_winds_up_before_each_pulse :: proc(t: ^testing.T) {
	f: Beam_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !beam_fixture(t, &f) {
		return
	}
	s := f.s
	p := sim.player_at(s, 0)
	wd := &f.defs.weapons[f.db]
	loadout.slots_of(s, 0).loadout[0] = f.db
	weapon_system.change_weapon(s, p.weapons, sim.WEP_AIR, f.db)
	wind := new_weapons.beam_windup(wd)
	fired := make([dynamic]int, context.temp_allocator)
	for i in 0 ..< 60 {
		sim.session_step(s, {i % 2 == 0 ? {.Fire_Air} : {}, {}})
		if len(new_weapons.beam_shots(s)) > 0 {
			append(&fired, i)
		}
	}
	if testing.expect(t, len(fired) >= 3) {
		testing.expect_value(t, fired[0], int(wind))
		cycle := int(wind + wd.delay_between_launches + 1)
		for k in 1 ..< len(fired) {
			// The next press lands on an even step.
			gap := fired[k] - fired[k - 1]
			testing.expectf(t, gap == cycle || gap == cycle + 1, "pulses %d steps apart, want %d", gap, cycle)
		}
	}
}


// The Weapon 6 passive: its damage scales a pulse, a release and the
// fragments of the release's motes; the beam's width takes the damage's
// percentage and its own.
@(test)
discharge_beam_passive_hits_harder_and_wider :: proc(t: ^testing.T) {
	f: Beam_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !beam_fixture(t, &f, true) {
		return
	}
	s := f.s
	pl := sim.player_at(s, 0)
	h := pl.weapons
	h.air.weapon = f.db
	wd := &f.defs.weapons[f.db]
	b := new_weapons.beam_def(wd)
	at := sim.Vec{208, 420}
	top := wd.powerup_air_max_power_level
	wall := mine_spawn(t, s, at + {0, -100}, 100)
	if wall.obj == nil {
		return
	}
	passives.levels_of(s, pl.number)^ = #partial {.Weapon_6 = 3}
	dmg := i32(passives.PASSIVES[.Weapon_6].mods[0].at[2])
	wide := i32(passives.PASSIVES[.Weapon_6].mods[1].at[2])
	scale := proc(v: f32, pct: i32) -> f32 {return v * f32(100 + pct) / 100}

	s.effects.count = 0
	new_weapons.beam_shot(s, h, wd, at, sim.single(s, sim.Clock).time)
	testing.expect(t, abs(100 - wall.shields - scale(b.damage, dmg)) < 1e-3, "a pulse deals the scaled damage")
	shots := new_weapons.beam_shots(s)
	if testing.expect_value(t, len(shots), 1) {
		testing.expect(t, abs(shots[0].width - scale(b.width, dmg + wide)) < 1e-3, "a pulse is as wide as both percentages")
	}

	wall.last_hit = -100
	before := wall.shields
	s.effects.count = 0
	new_weapons.beam_release(s, h, wd, at, top, sim.single(s, sim.Clock).time)
	testing.expect(t, abs(before - wall.shields - scale(b.release_damage, dmg)) < 1e-3, "a release deals the scaled damage")
	shots = new_weapons.beam_shots(s)
	if testing.expect_value(t, len(shots), 1) {
		testing.expect(t, abs(shots[0].width - scale(b.release_width, dmg + wide)) < 1e-3)
	}
	// The motes carry the weapon, so their fragments deal its damage.
	for used, i in sim.single(s, sim.Pool).entity_used {
		e := sim.entity_at(s, i32(i))
		if used && !e.deleted && e.unit == sim.unit_index(s.defs, b.mote) {
			testing.expect_value(t, e.shaped_by, stats.shot_shaper(s, 0, f.db))
			testing.expect(t, abs(stats.shot_damage(s, e, 0.4) - scale(0.4, dmg)) < 1e-3)
			break
		}
	}
}
