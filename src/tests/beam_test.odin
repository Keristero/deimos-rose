package tests

import "core:log"
import "core:os"
import "core:testing"
import vmem "core:mem/virtual"

import "dr:data"
import "dr:sim"

// The Discharge Beam (sim/beam.odin): an instant line that carries its
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

// Stage 1 in a New Weapons session, once the ship is in play.
@(private = "file")
beam_fixture :: proc(t: ^testing.T, f: ^Beam_Fixture) -> bool {
	if !os.exists("assets/data/index.json") || !os.exists("assets/extra") {
		log.info("skipped: needs the extracted assets tree")
		return false
	}
	testing.expect(t, vmem.arena_init_growing(&f.arena) == nil)
	alloc := vmem.arena_allocator(&f.arena)
	f.defs, _ = data.assets_defs_load("assets", alloc)
	if _, ok := data.extra_defs_load("assets", &f.defs, alloc); !testing.expect(t, ok) {
		return false
	}
	f.db = -1
	for &w, i in f.defs.weapons {
		if w.id == sim.res_id("aidb") {
			f.db = i32(i)
		}
	}
	if !testing.expect(t, f.db >= 0, "no Discharge Beam in assets/extra") {
		return false
	}
	f.s = new(sim.State, alloc)
	sim.init(f.s, sim.Session{seed = 1, level_id = f.defs.levels[0].id, game_type = .Single, loadout = true}, &f.defs)
	for i := 0; i < 300 && f.s.players[0].state != .Playing; i += 1 {
		sim.session_step(f.s, {})
	}
	return testing.expect(t, f.s.players[0].state == .Playing, "the ship must be in play")
}

// A stationary target in the air (the mine) at `loc` with `shields`.
@(private = "file")
beam_target :: proc(t: ^testing.T, s: ^sim.State, loc: sim.Vec, shields: f32) -> ^sim.Entity {
	req := sim.spawn_request(sim.res_id("mine"))
	req.loc = loc
	req.stationary = true
	r := sim.eg_request_spawn(s, req)
	if !testing.expect(t, sim.ref_valid(s, r), "the target must spawn") {
		return nil
	}
	e := sim.entity_at(s, r.index)
	e.loc = loc // the unit spawns at a random offset
	e.appear_delay = 0
	e.shields = shields
	return e
}

@(private = "file")
count_unit :: proc(s: ^sim.State, id: sim.Res_ID) -> (n: int) {
	ui := sim.unit_index(s.defs, id)
	for &e, i in s.world.entities {
		if s.world.entity_used[i] && !e.deleted && e.unit == i32(ui) {
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
	testing.expect(t, w.extra && w.beam.on)
	testing.expect_value(t, w.type, sim.WEP_AIR)
	testing.expect_value(t, w.minimum_level_available, 10)
	testing.expect(t, w.beam.damage > 0 && w.beam.release_damage > w.beam.damage)
	testing.expect(t, w.beam.release_width > w.beam.width, "a charged beam is wider")
	testing.expect_value(t, w.beam.shrapnel_count, 3)
	for id in ([]sim.Res_ID{w.beam.shrapnel, w.spawns[0].unit, w.powerup_air_activation_spawn, w.powerup_air_release_spawn}) {
		testing.expectf(t, sim.unit_index(&f.defs, id) >= 0, "unit %v must load", id)
	}
	testing.expect(t, f.defs.units[sim.unit_index(&f.defs, w.beam.shrapnel)].player_projectile, "shrapnel is a player shot")
	testing.expect(t, !f.defs.units[sim.unit_index(&f.defs, w.spawns[0].unit)].player_projectile, "the beam itself is not a projectile")
	for level in i32(1) ..= 12 {
		testing.expect(t, sim.best_air_weapon(&f.defs, level) != f.db)
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
	h := &s.players[0].weapons
	wd := &f.defs.weapons[f.db]
	at := sim.Vec{208, 420}
	far := beam_target(t, s, at + {0, -240}, 5)
	near := beam_target(t, s, at + {0, -80}, 1)
	mid := beam_target(t, s, at + {0, -160}, 1)
	aside := beam_target(t, s, at + {60, -120}, 1)
	if far == nil || near == nil || mid == nil || aside == nil {
		return
	}
	shrapnel := count_unit(s, wd.beam.shrapnel)
	s.beams.count = 0
	sim.beam_fire(s, h, wd, at, 2.5, wd.beam.width, false, s.time)
	testing.expect(t, near.deleted, "the first target must die")
	testing.expect(t, mid.deleted, "the leftover must kill the second")
	testing.expect(t, !far.deleted && abs(far.shields - 4.5) < 1e-4, "the third takes the last 0.5")
	testing.expect(t, !aside.deleted && aside.shields == 1, "off the line is not hit")
	testing.expect_value(t, count_unit(s, wd.beam.shrapnel) - shrapnel, 6)
	if testing.expect_value(t, s.beams.count, 1) {
		ev := s.beams.events[0]
		testing.expect_value(t, ev.to_y, far.loc.y)
		testing.expect(t, !ev.charged && ev.from.x == at.x && ev.from.y < at.y)
	}
	// Again on the same step: the hit delay protects the third, and the
	// beam stops there without dealing anything.
	sim.beam_fire(s, h, wd, at, 2.5, wd.beam.width, false, s.time)
	testing.expect(t, abs(far.shields - 4.5) < 1e-4)
	testing.expect_value(t, s.beams.events[1].to_y, far.loc.y)
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
	one := beam_target(t, s, {8, 300}, 0.5)
	if one == nil {
		return
	}
	s.beams.count = 0
	sim.beam_fire(s, &s.players[0].weapons, wd, {8, 420}, 2, wd.beam.width, false, s.time)
	testing.expect(t, one.deleted)
	testing.expect(t, s.beams.count == 1 && s.beams.events[0].to_y < 0)
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
	h := &s.players[0].weapons
	wd := &f.defs.weapons[f.db]
	at := sim.Vec{208, 420}
	top := wd.powerup_air_max_power_level
	wall := beam_target(t, s, at + {0, -100}, 100)
	if wall == nil {
		return
	}
	s.beams.count = 0
	sim.beam_release(s, h, wd, at, top, s.time)
	testing.expect(t, abs(100 - wall.shields - wd.beam.release_damage) < 1e-3, "a full charge deals the release damage")
	testing.expect(t, s.beams.count == 1 && s.beams.events[0].charged && s.beams.events[0].width == wd.beam.release_width)
	wall.last_hit = -100
	before := wall.shields
	sim.beam_release(s, h, wd, at, top / 2, s.time)
	testing.expect(t, abs(before - wall.shields - wd.beam.release_damage / 2) < 1e-3, "half a charge deals half")
}

// Through the fire button: a press fires a pulse on the step it lands, and
// holding charges it; letting go releases one charged beam.
@(test)
discharge_beam_fires_from_the_button :: proc(t: ^testing.T) {
	f: Beam_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !beam_fixture(t, &f) {
		return
	}
	s := f.s
	p := &s.players[0]
	p.weapons.loadout[0] = f.db
	sim.change_weapon(s, &p.weapons, sim.WEP_AIR, f.db)
	pulses, charged := 0, 0
	for i in 0 ..< 120 {
		sim.session_step(s, {i < 100 ? {.Fire_Air} : {}, {}})
		for ev in s.beams.events[:s.beams.count] {
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
