package new_weapon_passives_tests

// New Weapon Upgrades (plugins/new_weapon_passives): when the companion is
// on (D66), and its passives. A package of the plugin's own, as each
// plugin owns the tests of what it adds; the helpers are tests/support's.
// The passives' tests run against the shipped content, so each is skipped
// without the assets tree.

import "base:runtime"
import "core:strings"
import "core:testing"
import vmem "core:mem/virtual"

// Every plugin in the build, registered as the game registers them.
import "dr:game"
import "dr:net"
import "dr:plugins/accent"
import "dr:plugins/chaingun"
import "dr:plugins/easy_mode"
import "dr:plugins/new_weapon_passives"
import "dr:plugins/new_weapons"
import "dr:plugins/passives"
import "dr:prefs"
import "dr:sim"
import "dr:sim/lifecycle"
import "dr:sim/stats"
import "dr:sim/systems/collision_system"
import support "dr:tests/support"

@(init)
setup :: proc "contextless" () {
	context = runtime.default_context()
	sim.register_all()
}

// The plugin, as a member of a sim.Mods.
@(private = "file")
companion :: proc() -> int {
	return int(new_weapon_passives.ID)
}

// Easy Mode (which brings Passive Upgrades), New Weapons and the Chaingun,
// as a player who turned those on has them: the companion with them.
@(private = "file")
session_mods :: proc() -> sim.Mods {
	return sim.mods_session(sim.mods_switch_on({}, {int(easy_mode.ID), int(new_weapons.ID), int(chaingun.ID)}))
}

@(test)
comes_on_with_both_and_brings_neither :: proc(t: ^testing.T) {
	testing.expect(t, companion() in session_mods())
	// On its own, New Weapons leaves Passive Upgrades and the companion off.
	mods := sim.mods_switch_on({}, {int(new_weapons.ID)})
	testing.expect(t, int(passives.ID) not_in mods && companion() not_in mods)
	// Easy Mode brings Passive Upgrades, the last it needed.
	mods = sim.mods_switch_on(mods, {int(easy_mode.ID)})
	testing.expect(t, companion() in mods)
	// Turned off alone, it stays off as other mods come on.
	prefs.mod_toggle(&mods, new_weapon_passives.ID)
	testing.expect(t, companion() not_in mods && int(passives.ID) in mods && int(new_weapons.ID) in mods)
	prefs.mod_toggle(&mods, accent.ID)
	testing.expect(t, companion() not_in mods)
	prefs.mod_toggle(&mods, new_weapon_passives.ID)
	testing.expect(t, companion() in mods)
	// Either dependency turned off takes it.
	prefs.mod_toggle(&mods, passives.ID)
	testing.expect(t, companion() not_in mods && int(new_weapons.ID) in mods)
	// A switch for a group does not turn Passive Upgrades on for it.
	testing.expect(t, companion() not_in sim.mods_default_dependants(new_weapons.ID))
}

// A new player has New Weapons but not Passive Upgrades.
@(test)
new_players_start_without_it :: proc(t: ^testing.T) {
	defaults := prefs.defaults().mods
	testing.expect(t, int(new_weapons.ID) in defaults)
	testing.expect(t, int(passives.ID) not_in defaults && companion() not_in defaults)
}

// Saved as off where both are on, so a save from before the plugin brings
// it on for a player who has both.
@(test)
saved_as_off :: proc(t: ^testing.T) {
	p := prefs.defaults()
	p.mods = sim.mods_switch_on(p.mods, {int(easy_mode.ID)})
	text := prefs.format(&p, context.temp_allocator)
	testing.expect_value(t, prefs.parse(text).mods, p.mods)
	testing.expect(t, strings.contains(text, "\nmods_off=\n"), text)

	prefs.mod_toggle(&p.mods, new_weapon_passives.ID)
	text = prefs.format(&p, context.temp_allocator)
	testing.expect(t, strings.contains(text, "\nmods_off=new_weapon_passives\n"), text)
	testing.expect_value(t, prefs.parse(text).mods, p.mods)

	older := prefs.parse("mods=extra_prefs,loadout,new_weapons,passives,easy_mode")
	testing.expect(t, companion() in older.mods)
	testing.expect(t, companion() not_in prefs.parse("mods=extra_prefs,loadout,new_weapons").mods)
}

// An older build's Start flags: with both, as that build had these
// passives in Passive Upgrades.
@(test)
older_start_flags :: proc(t: ^testing.T) {
	testing.expect(t, companion() in game.mods_from_flags(net.START_EASY | net.START_LOADOUT))
	testing.expect(t, companion() not_in game.mods_from_flags(net.START_LOADOUT))
	testing.expect(t, companion() not_in game.mods_from_flags(net.START_EASY))
}

// Stage 1 with the plugins' content, in session_mods, once the ship is in
// play.
@(private = "file")
Fixture :: struct {
	arena: vmem.Arena,
	defs:  sim.Defs,
	s:     ^sim.State,
}

@(private = "file")
fixture :: proc(t: ^testing.T, f: ^Fixture) -> bool {
	f.defs = support.content_defs(t, &f.arena, "plugins/new_weapons/data") or_return
	alloc := vmem.arena_allocator(&f.arena)
	f.s = new(sim.State, alloc)
	context.allocator = alloc // the state's world goes in the arena too
	session := sim.Session{seed = 1, level_id = f.defs.levels[0].id, game_type = .Single, mods = session_mods()}
	return support.play_start(t, f.s, session, &f.defs)
}

// Each passive is offered from the level its weapon is, and only with the
// companion on.
@(test)
offered_from_their_weapons_levels :: proc(t: ^testing.T) {
	f: Fixture
	defer vmem.arena_destroy(&f.arena)
	if !fixture(t, &f) {
		return
	}
	s := f.s
	testing.expect(t, passives.passive_available(s, new_weapon_passives.WEAPON_5, 9))
	testing.expect(t, !passives.passive_available(s, new_weapon_passives.WEAPON_6, 9))
	testing.expect(t, passives.passive_available(s, new_weapon_passives.WEAPON_6, 10))
	testing.expect(t, !passives.passive_available(s, new_weapon_passives.WEAPON_6_CHARGE, 9))
	testing.expect(t, passives.passive_available(s, new_weapon_passives.WEAPON_6_CHARGE, 10))
	s.session.mods -= {companion()}
	testing.expect(t, !passives.passive_available(s, new_weapon_passives.WEAPON_5, 9))
	testing.expect(t, !passives.passive_available(s, new_weapon_passives.WEAPON_6, 10))
	testing.expect(t, !passives.passive_available(s, new_weapon_passives.WEAPON_6_CHARGE, 10))
	// Nor the Chaingun's without the Chaingun's plugin.
	s.session.mods += {companion()}
	s.session.mods -= {int(chaingun.ID)}
	testing.expect(t, !passives.passive_available(s, new_weapon_passives.WEAPON_5, 9))
	testing.expect(t, passives.passive_available(s, new_weapon_passives.WEAPON_6, 10))
}

// The Chaingun's rounds stray further with its passive; a unit that flies
// straight still does, and another weapon's shots are left alone.
@(test)
chaingun_passive_widens_the_spread :: proc(t: ^testing.T) {
	f: Fixture
	defer vmem.arena_destroy(&f.arena)
	if !fixture(t, &f) {
		return
	}
	s := f.s
	cg := support.weapon_index(t, &f.defs, new_weapon_passives.WEAPON_CHAINGUN)
	ion := support.weapon_index(t, &f.defs, passives.WEAPON_ION_CANNON)
	if cg < 0 || ion < 0 {
		return
	}
	passives.levels_of(s, 0)[new_weapon_passives.WEAPON_5] = 3
	by := stats.shot_shaper(s, 0, cg)
	testing.expect(t, by != 0)
	testing.expect_value(t, stats.heading_tolerance(s, 0, by, false, 8), 16)
	testing.expect_value(t, stats.heading_tolerance(s, 0, by, false, 0), 0)
	testing.expect_value(t, stats.heading_tolerance(s, 0, by, false, 270), 360)
	testing.expect_value(t, stats.heading_tolerance(s, 0, stats.shot_shaper(s, 0, ion), false, 8), 8)
	testing.expect_value(t, stats.heading_tolerance(s, 0, 0, false, 8), 8)
}

// The Discharge Beam's passive: its damage scales a pulse and a release;
// the beam's width takes the damage's percentage and its own.
@(test)
discharge_beam_passive_hits_harder_and_wider :: proc(t: ^testing.T) {
	f: Fixture
	defer vmem.arena_destroy(&f.arena)
	if !fixture(t, &f) {
		return
	}
	s := f.s
	db := support.weapon_index(t, &f.defs, new_weapon_passives.WEAPON_DISCHARGE_BEAM)
	if db < 0 {
		return
	}
	pl := sim.player_at(s, 0)
	h := pl.weapons
	h.air.weapon = db
	wd := &f.defs.weapons[db]
	b := new_weapons.beam_def(wd)
	at := sim.Vec{208, 420}
	top := wd.powerup_air_max_power_level
	wall := support.mine_spawn(t, s, at + {0, -100}, 100)
	if wall.obj == nil {
		return
	}
	passives.levels_of(s, pl.number)[new_weapon_passives.WEAPON_6] = 3
	def := passives.passive_def(new_weapon_passives.WEAPON_6)
	dmg, wide := i32(def.mods[0].at[2]), i32(def.mods[1].at[2])
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
}

// The Discharge Beam in play for player 1, with the stage's own targets
// taken away so a chain can only reach the test's.
@(private = "file")
beam_ready :: proc(t: ^testing.T, f: ^Fixture) -> (h: ^sim.Weapon_Handler, wd: ^sim.Weapon, ok: bool) {
	db := support.weapon_index(t, &f.defs, new_weapon_passives.WEAPON_DISCHARGE_BEAM)
	if db < 0 {
		return
	}
	walk := sim.walk_entities(f.s)
	for e in sim.walk_next(&walk) {
		if collision_system.air_shot_can_hit(f.s, e) {
			lifecycle.entity_delete(e)
		}
	}
	h = sim.player_at(f.s, 0).weapons
	h.air.weapon = db
	return h, &f.defs.weapons[db], true
}

// The Discharge Beam's charge passive: the release goes straight to its
// first target, then jumps from each kill to the nearest it has not hit
// (not the next along the line), a run for each, and stops on a target
// left standing. From level 2 the charge climbs higher.
@(test)
discharge_beam_charge_chains_its_release :: proc(t: ^testing.T) {
	f: Fixture
	defer vmem.arena_destroy(&f.arena)
	if !fixture(t, &f) {
		return
	}
	s := f.s
	h, wd, ok := beam_ready(t, &f)
	if !ok {
		return
	}
	at := sim.Vec{208, 420}
	first := support.mine_spawn(t, s, at + {0, -60}, 1)
	near := support.mine_spawn(t, s, at + {-50, -90}, 1) // 58 px from the first
	far := support.mine_spawn(t, s, at + {80, -60}, 1) // 80 from the first, 133 from the near
	wall := support.mine_spawn(t, s, at + {0, -200}, 100) // 121 from the near
	if first.obj == nil || near.obj == nil || far.obj == nil || wall.obj == nil {
		return
	}
	levels := passives.levels_of(s, 0)
	levels[new_weapon_passives.WEAPON_6_CHARGE] = 1
	top := wd.powerup_air_max_power_level
	testing.expect_value(t, stats.powerup_max_level(s, h, h.air.weapon), top)

	s.effects.count = 0
	new_weapons.beam_release(s, h, wd, at, top, sim.single(s, sim.Clock).time)
	testing.expect(t, first.deleted && near.deleted, "the first and the nearest to it die")
	testing.expect(t, !far.deleted && far.shields == 1, "the far one is passed over")
	release := new_weapons.beam_def(wd).release_damage
	testing.expect(t, abs(100 - wall.shields - (release - 2)) < 1e-4, "the wall takes what is left")
	runs := new_weapons.beam_shots(s)
	if testing.expect_value(t, len(runs), 3) {
		testing.expect(t, runs[0].from.x == at.x && runs[0].to == first.loc, "straight up to the first")
		testing.expect(t, runs[1].from == first.loc && runs[1].to == near.loc)
		testing.expect(t, runs[2].from == near.loc && runs[2].to == wall.loc)
		for r in runs {
			testing.expect(t, r.charged && r.player == 0)
		}
	}

	levels[new_weapon_passives.WEAPON_6_CHARGE] = 3
	testing.expect(t, stats.powerup_max_level(s, h, h.air.weapon) > top, "level 3 charges higher")
}

// A chain carries its damage as a straight beam does, and stops where it
// is spent; the passive leaves the pulses piercing straight on.
@(test)
discharge_beam_charge_chain_spends_its_damage :: proc(t: ^testing.T) {
	f: Fixture
	defer vmem.arena_destroy(&f.arena)
	if !fixture(t, &f) {
		return
	}
	s := f.s
	h, wd, ok := beam_ready(t, &f)
	if !ok {
		return
	}
	at := sim.Vec{208, 420}
	first := support.mine_spawn(t, s, at + {0, -60}, 1)
	beside := support.mine_spawn(t, s, at + {50, -60}, 1)
	next := support.mine_spawn(t, s, at + {0, -150}, 1)
	if first.obj == nil || beside.obj == nil || next.obj == nil {
		return
	}
	passives.levels_of(s, 0)[new_weapon_passives.WEAPON_6_CHARGE] = 3
	width := new_weapons.beam_def(wd).width
	time := sim.single(s, sim.Clock).time

	s.effects.count = 0
	new_weapons.beam_fire(s, h, wd, at, 2, width, false, time)
	testing.expect(t, first.deleted && next.deleted && !beside.deleted, "a pulse pierces straight on")
	testing.expect_value(t, len(new_weapons.beam_shots(s)), 1)

	// On a target beside, on a later step: the charge's chain kills the
	// first and the one beside, and its 2 damage is spent there.
	again := support.mine_spawn(t, s, at + {0, -150}, 1)
	if again.obj == nil {
		return
	}
	first = support.mine_spawn(t, s, at + {0, -60}, 1)
	if first.obj == nil {
		return
	}
	s.effects.count = 0
	new_weapons.beam_fire(s, h, wd, at, 2, width, true, time + 2)
	testing.expect(t, first.deleted && beside.deleted, "the chain jumps to the one beside")
	testing.expect(t, !again.deleted && again.shields == 1, "and is spent there")
	runs := new_weapons.beam_shots(s)
	if testing.expect_value(t, len(runs), 2) {
		testing.expect_value(t, runs[1].to, beside.loc)
	}
}

// The steps between the first volleys of a release, driven the way
// air_powerup_process drives it.
@(private = "file")
release_gaps :: proc(s: ^sim.State, h: ^sim.Weapon_Handler, weapon: i32) -> (gaps: [8]i32) {
	p := sim.Powerup{state = 3, release_time = -100}
	n := 0
	for time in i32(1) ..= 100 {
		if n == len(gaps) {
			break
		}
		if stats.powerup_release_due(s, h, &p, weapon, time) {
			if p.released > 0 {
				gaps[n] = time - p.release_time
				n += 1
			}
			p.release_time = time
			p.released += 1
		}
	}
	return
}

// The Chaingun's charge passive: its release's volleys come every 3 steps,
// as the weapon's data has them, then closer as it fires, down to one
// every 2, the most hits one target takes. Each level charges higher.
@(test)
chaingun_charge_ramps_its_release :: proc(t: ^testing.T) {
	f: Fixture
	defer vmem.arena_destroy(&f.arena)
	if !fixture(t, &f) {
		return
	}
	s := f.s
	cg := support.weapon_index(t, &f.defs, new_weapon_passives.WEAPON_CHAINGUN)
	if cg < 0 {
		return
	}
	h := sim.player_at(s, 0).weapons
	h.air.weapon = cg
	testing.expect_value(t, f.defs.weapons[cg].powerup_air_time_between_release_spawns, 2)
	testing.expect_value(t, release_gaps(s, h, cg), [8]i32{3, 3, 3, 3, 3, 3, 3, 3})
	top := stats.powerup_max_level(s, h, cg)

	levels := passives.levels_of(s, 0)
	levels[new_weapon_passives.WEAPON_5_CHARGE] = 1
	testing.expect_value(t, release_gaps(s, h, cg), [8]i32{3, 2, 2, 2, 2, 2, 2, 2})
	testing.expect(t, stats.powerup_max_level(s, h, cg) > top)
	levels[new_weapon_passives.WEAPON_5_CHARGE] = 3
	testing.expect_value(t, release_gaps(s, h, cg), [8]i32{3, 2, 2, 2, 2, 2, 2, 2})
	// Its shots are left alone, and a passive for another weapon's charge
	// does not ramp this one.
	testing.expect_value(t, stats.weapon_stat(s, 0, cg, .Release_Ramp).percent, 0)
	levels[new_weapon_passives.WEAPON_5_CHARGE] = 0
	levels[new_weapon_passives.WEAPON_6_CHARGE] = 3
	testing.expect_value(t, release_gaps(s, h, cg), [8]i32{3, 3, 3, 3, 3, 3, 3, 3})
}

