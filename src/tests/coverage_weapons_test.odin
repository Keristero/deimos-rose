package tests

import "core:log"
import "core:os"
import "core:testing"
import vmem "core:mem/virtual"

import "dr:data"
import "dr:plugins/easy_mode"
import "dr:plugins/loadout"
import "dr:plugins/passives"
import "dr:sim"
import "dr:sim/lifecycle"
import "dr:sim/stats"
import "dr:sim/systems/player_system"
import "dr:sim/systems/weapon_system"

// The weapon handler's less travelled paths (G_WeaponHandler in
// sim/systems/weapon_system), the stats plugins can change (sim/stats), and
// the passives, loadout and reward screens' edges. The synthetic tests need
// nothing but the repository; those against the shipped weapons are
// skipped without the assets tree.

// Synthetic fixtures.

// A session over `defs`, its world in the test's arena (context.allocator).
@(private = "file")
cw_session :: proc(defs: ^sim.Defs, mods: sim.Mods = {}, game_type := sim.Game_Type.Single) -> ^sim.State {
	s := new(sim.State)
	sim.init(s, sim.Session{seed = 3, level_id = defs.levels[0].id, game_type = game_type, mods = mods}, defs)
	return s
}

// The synthetic fixture with its air weapon made a charging one, as the
// original's are: a press fires once, holding charges a power-up of 20
// levels, one every 3 steps after 15 steps held, overheating 180 steps in.
// The release unit is never spawned by the tests that use it.
@(private = "file")
cw_charged_defs :: proc() -> ^sim.Defs {
	d := synthetic_defs()
	d.perm_floats[0x20] = 30 // steps a second
	w := &d.weapons[0]
	w.auto_repeat = false
	w.delay_between_launches = 4
	w.powerup_air_release_spawn = sim.res_id("rels")
	w.powerup_air_time_until_activation = 15
	w.powerup_air_time_between_power_level_changes = 2
	w.powerup_air_max_power_level = 20
	w.powerup_air_overload_time = 180
	return d
}

// Two short levels of the synthetic fixture, so that a level ends quickly.
// With `wai2`, a second air weapon from level 2, for the loadout screen.
@(private = "file")
cw_two_level_defs :: proc(wai2 := false) -> ^sim.Defs {
	defs := synthetic_defs()
	levels := make([]sim.Level_Def, 2, context.temp_allocator)
	for &l, i in levels {
		l = defs.levels[0]
		l.id = sim.level_id(i == 0 ? "le01" : "le02")
		l.number = i32(i + 1)
		l.background.bottom = 700
	}
	defs.levels = levels
	defs.perm_floats[0x20] = 30
	if wai2 {
		weapons := make([]sim.Weapon, 3, context.temp_allocator)
		copy(weapons, defs.weapons)
		weapons[2] = defs.weapons[0]
		weapons[2].id = sim.res_id("wai2")
		weapons[2].minimum_level_available = 2
		defs.weapons = weapons
	}
	return defs
}

@(private = "file")
cw_gap :: proc(s: ^sim.State, site: sim.Site) -> bool {
	for g in s.gaps[:s.gap_count] {
		if g.site == site {
			return true
		}
	}
	return false
}

@(private = "file")
cw_sounded :: proc(s: ^sim.State, id: sim.Res_ID) -> bool {
	for e in s.sounds.events[:s.sounds.count] {
		if e.id == id {
			return true
		}
	}
	return false
}

// A press for each player, then letting go, for the next press edge.
@(private = "file")
cw_press :: proc(s: ^sim.State, a: sim.Buttons, b: sim.Buttons = {}) -> sim.Level_Transition {
	if tr := sim.session_step(s, {a, b}); tr != .None {
		return tr
	}
	return sim.session_step(s, {})
}

// Weapon selection.

// FUN_00448830 picks the weapon marked default for air or ground, wherever
// it sits in the list; G_WepDef_MasterList_GetNextRefPtrByType from no
// weapon at all takes the first of the type available at the level.
@(test)
weapon_defaults_and_first_of_type :: proc(t: ^testing.T) {
	d := synthetic_defs()
	weapons := make([]sim.Weapon, 3, context.temp_allocator)
	weapons[0] = d.weapons[0]
	weapons[0].id = sim.res_id("wai3")
	weapons[0].default = sim.NONE
	weapons[0].minimum_level_available = 3
	weapons[1] = d.weapons[1]
	weapons[2] = d.weapons[0] // the default air weapon, from level 1
	d.weapons = weapons
	testing.expect_value(t, weapon_system.default_weapon(d, false), 2)
	testing.expect_value(t, weapon_system.default_weapon(d, true), 1)
	testing.expect_value(t, weapon_system.next_weapon_of_type(d, sim.WEP_AIR, sim.NONE, 1), 2)
	testing.expect_value(t, weapon_system.next_weapon_of_type(d, sim.WEP_AIR, sim.NONE, 3), 0)
	testing.expect_value(t, weapon_system.next_weapon_of_type(d, sim.WEP_GROUND, sim.NONE, 1), 1)
}

// G_WeaponHandler::ChangeWeapon for the ground: the same weapon only drops
// what was queued; another takes over at once, its burst dropped, unless a
// ground power-up is under way, when it waits in the queue. The queue is
// taken up at the next appearance (SetUpForAppearance).
@(test)
ground_weapon_change_waits_for_its_power_up :: proc(t: ^testing.T) {
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	d := synthetic_defs()
	weapons := make([]sim.Weapon, 3, context.temp_allocator)
	copy(weapons, d.weapons)
	weapons[2] = d.weapons[1]
	weapons[2].id = sim.res_id("wgn2")
	weapons[2].default = sim.NONE
	d.weapons = weapons
	s := cw_session(d)
	h := sim.player_at(s, 0).weapons
	if !testing.expect_value(t, h.ground.weapon, 1) {
		return
	}
	h.queued_ground = 2
	weapon_system.change_weapon(s, h, sim.WEP_GROUND, 1)
	testing.expect_value(t, h.ground.weapon, 1)
	testing.expect_value(t, h.queued_ground, sim.NO_WEAPON)

	h.ground.pending = 3
	weapon_system.change_weapon(s, h, sim.WEP_GROUND, 2)
	testing.expect_value(t, h.ground.weapon, 2)
	testing.expect_value(t, h.ground.pending, 0)
	testing.expect_value(t, h.queued_ground, sim.NO_WEAPON)

	h.ground_powerup.state = 1
	weapon_system.change_weapon(s, h, sim.WEP_GROUND, 1)
	testing.expect_value(t, h.ground.weapon, 2)
	testing.expect_value(t, h.queued_ground, 1)

	h.ground_powerup.state = 0
	weapon_system.weapons_appear(s, h, false)
	testing.expect_value(t, h.ground.weapon, 1)
	testing.expect_value(t, h.queued_ground, sim.NO_WEAPON)
}

// Process ends a ground power-up when fire-ground is let go, as it does the
// air's; the ground power-up itself (0x44741a) is not ported, and a ground
// weapon that has one says so.
@(test)
letting_go_of_fire_ground_releases_its_power_up :: proc(t: ^testing.T) {
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	d := synthetic_defs()
	s := cw_session(d)
	h := sim.player_at(s, 0).weapons
	h.ground_powerup = {state = 1, entity = -1}
	result, _ := weapon_system.weapons_process(s, h, {208, 330}, false, false, false, 50)
	testing.expect_value(t, result, sim.Weapon_Result.Released)
	testing.expect_value(t, h.ground_powerup.state, 3)
	testing.expect_value(t, h.ground_powerup.time, 50)
	testing.expect(t, !cw_gap(s, sim.Site(0x44741a)), "a ground weapon without a power-up is ported")

	d.weapons[1].powerup_ground_activation_spawn = sim.res_id("gpup")
	weapon_system.weapons_process(s, h, {208, 330}, false, false, false, 51)
	testing.expect(t, cw_gap(s, sim.Site(0x44741a)), "a ground power-up must be marked unported")
}

// Auxiliary weapons (the original's third kind, which no shipped weapon is):
// appearing resets their timers; each fires on its own delay while fire-air
// is down, and a non-repeating one only on the press. What they spawn
// (Priv_Spawn_Auxilary) and the list ChangeWeapon keeps of them are not
// ported, and are marked.
@(test)
auxiliary_weapons_fire_on_their_own_delay :: proc(t: ^testing.T) {
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	d := synthetic_defs()
	weapons := make([]sim.Weapon, 3, context.temp_allocator)
	copy(weapons, d.weapons)
	weapons[2] = d.weapons[0]
	weapons[2].id = sim.res_id("waux")
	weapons[2].type = sim.WEP_AUX
	weapons[2].default = sim.NONE
	weapons[2].auto_repeat = false
	weapons[2].delay_between_launches = 5
	d.weapons = weapons
	s := cw_session(d)
	h := sim.player_at(s, 0).weapons
	h.aux_count = 1
	h.aux[0] = {weapon = 2, last = 7, last2 = 7, pending = 2, flag_a = true}
	weapon_system.weapons_appear(s, h, false)
	testing.expect_value(t, h.aux[0], sim.Weapon_Slot{weapon = 2, flag_b = true})

	at := sim.Vec{208, 330}
	weapon_system.weapons_process(s, h, at, false, true, false, 10)
	testing.expect_value(t, h.aux[0].pending, 1)
	testing.expect_value(t, h.aux[0].last, 10)
	testing.expect(t, cw_gap(s, sim.Site(0x448590)), "the auxiliary spawn must be marked unported")
	// Held: a non-repeating auxiliary weapon waits for the next press.
	weapon_system.weapons_process(s, h, at, false, true, false, 20)
	testing.expect_value(t, h.aux[0].pending, 1)
	weapon_system.weapons_process(s, h, at, false, false, false, 21)
	weapon_system.weapons_process(s, h, at, false, true, false, 22)
	testing.expect_value(t, h.aux[0].pending, 2)
	// Pressed again within its delay: nothing.
	weapon_system.weapons_process(s, h, at, false, false, false, 23)
	weapon_system.weapons_process(s, h, at, false, true, false, 24)
	testing.expect_value(t, h.aux[0].pending, 2)

	weapon_system.change_weapon(s, h, sim.WEP_AUX, 2)
	testing.expect(t, cw_gap(s, sim.Site(0x447130)), "the auxiliary weapon list must be marked unported")
}

// Priv_AirPowerup_Process does nothing for a weapon with neither power-up
// spawn: a non-repeating weapon like that fires once a press and never
// charges however long fire-air is held.
@(test)
a_weapon_without_a_power_up_never_charges :: proc(t: ^testing.T) {
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	d := synthetic_defs()
	d.weapons[0].auto_repeat = false
	s := cw_session(d)
	h := sim.player_at(s, 0).weapons
	at := sim.Vec{208, 330}
	for time in i32(10) ..< 100 {
		weapon_system.weapons_process(s, h, at, false, true, false, time)
		testing.expect_value(t, h.air_powerup.state, 0)
	}
	testing.expect_value(t, h.air.pending, 1)
	weapon_system.weapons_process(s, h, at, false, false, false, 100)
	weapon_system.weapons_process(s, h, at, false, true, false, 101)
	testing.expect_value(t, h.air.pending, 2)
}

// Charging.

// Levels a power-up climbs in 300 steps, driven the way Process drives it.
@(private = "file")
cw_levels_in_300 :: proc(s: ^sim.State, h: sim.Weapons) -> (n: int) {
	p: sim.Powerup
	for time in i32(1) ..= 300 {
		if stats.powerup_level_due(s, h, &p, 0, time) {
			n += 1
			p.level_time = time
		}
	}
	return
}

// The original climbs a level every between + 1 steps: 100 levels in 300
// steps for a 2-step weapon. A changed Charge_Rate keeps pace in
// hundredths of a step, so Improved Charge's +30% (level 3) is exactly 130
// and Auto Charge's -50% exactly 50, however the steps fall; both held sum
// to -20%.
@(test)
charge_rate_paces_power_levels :: proc(t: ^testing.T) {
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := cw_session(cw_charged_defs(), session_mods(true, false))
	h := sim.player_at(s, 0).weapons
	lv := passives.levels_of(s, 0)
	testing.expect_value(t, cw_levels_in_300(s, h), 100)
	lv^[.Improved_Charge] = 1
	testing.expect_value(t, cw_levels_in_300(s, h), 110)
	lv^[.Improved_Charge] = 3
	testing.expect_value(t, cw_levels_in_300(s, h), 130)
	lv^[.Improved_Charge] = 0
	lv^[.Auto_Charge] = 1
	testing.expect_value(t, cw_levels_in_300(s, h), 50)
	lv^[.Improved_Charge] = 3
	testing.expect_value(t, cw_levels_in_300(s, h), 80)
}

// Auto Charge level 1 lengthens the time to overheat by half; level 2
// prevents it: a charge left to build (under Auto Charge, with the button
// up) overheats at level 1 and never at level 2.
@(test)
auto_charge_level_2_never_overheats :: proc(t: ^testing.T) {
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := cw_session(cw_charged_defs(), session_mods(true, false))
	h := sim.player_at(s, 0).weapons
	lv := passives.levels_of(s, 0)
	testing.expect_value(t, stats.powerup_overload_time(s, h, 0), 180)
	lv^[.Auto_Charge] = 1
	testing.expect_value(t, stats.powerup_overload_time(s, h, 0), 270)
	lv^[.Auto_Charge] = 2
	testing.expect_value(t, stats.powerup_overload_time(s, h, 0), 0)

	// Build a charge with the button up for 400 steps: the step it began
	// charging, and the step it overheated, if it did.
	idle :: proc(s: ^sim.State, h: sim.Weapons, from: i32) -> (charging, overheated: i32) {
		charging, overheated = -1, -1
		for time in from ..< from + 400 {
			result, _ := weapon_system.weapons_process(s, h, {208, 330}, false, false, false, time)
			if h.air_powerup.state == 1 && charging < 0 {
				charging = time
			}
			if result == .Overload && overheated < 0 {
				overheated = time
			}
		}
		return
	}
	lv^[.Auto_Charge] = 1
	charging, overheated := idle(s, h, 10)
	testing.expect(t, charging > 0, "Auto Charge must charge with the button up")
	testing.expect_value(t, h.air_powerup.state, 2)
	// The first step past the (lengthened) overload time.
	testing.expect_value(t, overheated - charging, 270 + 1)

	h.air_powerup = {entity = -1}
	h.air_idle = 0
	lv^[.Auto_Charge] = 2
	charging, overheated = idle(s, h, 500)
	testing.expect(t, charging > 0)
	testing.expect_value(t, overheated, -1)
	testing.expect_value(t, h.air_powerup.state, 1)
	testing.expect_value(t, h.air_powerup.level, 20)
}

// For the charge bar: how far a charge has climbed past the weapon's own
// max towards Improved Charge's raised one (20 to 26 at level 3), while it
// is charging or overheated; nothing without the passive, at or below the
// weapon's max, or when idle.
@(test)
overcharge_shows_the_charge_past_the_weapons_own_max :: proc(t: ^testing.T) {
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := cw_session(cw_charged_defs(), session_mods(true, false))
	p := sim.player_at(s, 0)
	h := p.weapons
	h.air.weapon = 0
	h.air_powerup = {state = 1, level = 20, entity = -1}
	testing.expect_value(t, stats.player_overcharge(s, p), 0)
	passives.levels_of(s, 0)^[.Improved_Charge] = 3
	testing.expect_value(t, stats.powerup_max_level(s, h, 0), 26)
	testing.expect_value(t, stats.player_overcharge(s, p), 0)
	h.air_powerup.level = 23
	testing.expect_value(t, stats.player_overcharge(s, p), 0.5)
	h.air_powerup.level = 26
	testing.expect_value(t, stats.player_overcharge(s, p), 1)
	h.air_powerup.state = 2
	h.air_powerup.level = 23
	testing.expect_value(t, stats.player_overcharge(s, p), 0.5)
	h.air_powerup.state = 0
	testing.expect_value(t, stats.player_overcharge(s, p), 0)
}

// Lanes.

// Extra lanes continue a spread whatever order the weapon lists its shots
// in, and a spawn entry naming no unit is neither a shot nor a lane. A
// synthetic Ion Cannon (the id Weapon 1 is for) listing its two shots right
// to left, 8 apart, with an empty entry between: one extra lane at level 1
// shifts them half a step, to -8, 0 and 8.
@(test)
extra_lanes_follow_the_spread_not_the_list :: proc(t: ^testing.T) {
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	d := synthetic_defs()
	shot := sim.res_id("shot")
	units := make([]sim.Unit, 1, context.temp_allocator)
	units[0] = {id = shot}
	units[0].player_projectile = true
	d.units = units
	d.weapons[0].id = passives.WEAPON_ION_CANNON
	spawns := []sim.Wep_Spawn_Def{{unit = shot, x_loc = 4}, {unit = sim.NONE}, {unit = shot, x_loc = -4}}
	d.weapons[0].spawns = spawns
	s := cw_session(d, session_mods(true, false))
	out: [stats.MAX_LANES + stats.MAX_EXTRA_SPAWNS]stats.Weapon_Spawn
	n := stats.weapon_spawns(s, 0, 0, false, out[:])
	testing.expect_value(t, n, 2) // no passive: the list as it is, bar the empty entry
	passives.levels_of(s, 0)^[.Weapon_1] = 1
	n = stats.weapon_spawns(s, 0, 0, false, out[:])
	if testing.expect_value(t, n, 3) {
		for x, i in ([3]i32{-8, 0, 8}) {
			testing.expectf(t, out[i].unit == shot && out[i].x == x, "lane %d at %d, want %d", i, out[i].x, x)
		}
	}
	// No lanes at all extend to none.
	lanes: [4]stats.Lane
	testing.expect_value(t, stats.lanes_extend({}, 2, lanes[:]), 0)
}

// Reward screen.

// The reward grid (REWARD_MAX_COLUMNS to a row): up and down move a whole
// row and stop at the top and bottom edges rather than wrapping.
@(test)
reward_grid_moves_a_row_at_a_time :: proc(t: ^testing.T) {
	testing.expect_value(t, easy_mode.reward_move(7, 9, {.Up}), 1)
	testing.expect_value(t, easy_mode.reward_move(1, 9, {.Down}), 7)
	testing.expect_value(t, easy_mode.reward_move(2, 9, {.Up}), 2)   // top row
	testing.expect_value(t, easy_mode.reward_move(4, 9, {.Down}), 4) // no cell below
	testing.expect_value(t, easy_mode.reward_move(8, 9, {.Right}), 0)
}

// Every passive on offer maxed: no screen, and the level moves straight on.
@(test)
no_reward_screen_when_nothing_is_left_to_take :: proc(t: ^testing.T) {
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	// The fixture's weapons are not the passives' weapons, so only the four
	// ship passives could be offered.
	s := cw_session(cw_two_level_defs(), session_mods(true, false))
	passives.levels_of(s, 0)^ = #partial {.Improved_Manoeuvring = 2, .Auto_Charge = 2, .Improved_Charge = 3, .Shield_Regen = 3}
	tr := sim.Level_Transition.None
	for i := 0; tr == .None && i < 10_000; i += 1 {
		tr = sim.session_step(s, {})
		testing.expect(t, !easy_mode.reward_open(s), "a reward screen with nothing to take")
	}
	testing.expect_value(t, tr, sim.Level_Transition.Advanced)
	testing.expect_value(t, sim.single(s, sim.Level_Info).number, 2)
}

// In co-op, a passive one player has maxed is still offered for the
// other. The player with nothing left to take cannot lock anything and is
// ready from the start; the screen closes on the other's choice. While it
// is open the session is frozen for the presentation.
@(test)
reward_screen_waits_only_for_players_with_something_to_take :: proc(t: ^testing.T) {
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := cw_session(cw_two_level_defs(), session_mods(true, false), .Co_Op)
	maxed := #partial passives.Passive_Levels{.Improved_Manoeuvring = 2, .Auto_Charge = 2, .Improved_Charge = 3, .Shield_Regen = 3}
	passives.levels_of(s, 0)^ = maxed
	for i := 0; i < 10_000 && !easy_mode.reward_open(s); i += 1 {
		testing.expect(t, !sim.session_frozen(s))
		if sim.session_step(s, {}) != .None {
			break
		}
	}
	rw := easy_mode.reward_of(s)
	if !testing.expect(t, rw.active, "the reward screen must open for the second player") {
		return
	}
	testing.expect(t, sim.session_frozen(s), "the reward screen must freeze the presentation")
	testing.expect_value(t, rw.count, 3)
	for k in 0 ..< rw.count {
		testing.expect(t, !easy_mode.reward_selectable(s, 0, k), "a maxed passive must not be selectable")
		testing.expect(t, easy_mode.reward_selectable(s, 1, k))
	}
	testing.expect(t, !easy_mode.reward_selectable(s, 1, rw.count), "no option past the last")
	testing.expect(t, easy_mode.reward_ready(s, 0))
	testing.expect(t, !easy_mode.reward_ready(s, 1))

	sim.session_step(s, {{.Fire_Air}, {}})
	testing.expect(t, cw_sounded(s, sim.SCREEN_SOUND_REFUSE), "a press with nothing to lock is refused")
	testing.expect(t, !rw.locked[0])
	sim.session_step(s, {})
	want := rw.options[rw.cursor[1]]
	tr := cw_press(s, {}, {.Fire_Air})
	testing.expect(t, rw.locked[1])
	for i := 0; tr == .None && i < sim.SCREEN_RESUME_DELAY + 2; i += 1 {
		tr = sim.session_step(s, {})
	}
	testing.expect_value(t, tr, sim.Level_Transition.Advanced)
	testing.expect(t, !sim.session_frozen(s))
	testing.expect_value(t, passives.levels_of(s, 0)^, maxed)
	testing.expect_value(t, passives.levels_of(s, 1)^[want], 1)
}

// Neither between-play screen opens when nobody is left in the game to
// choose.
@(test)
between_play_screens_need_a_chooser :: proc(t: ^testing.T) {
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := cw_session(cw_two_level_defs(true), session_mods(true, true))
	sim.player_at(s, 0).state = .Gone
	testing.expect(t, !easy_mode.reward_begin(s, {}))
	testing.expect(t, !easy_mode.reward_open(s))
	testing.expect(t, !loadout.loadout_begin(s, {}))
	testing.expect(t, !loadout.loadout_open(s))
}

// Loadout screen.

// Left and right wrap along the row the cursor is on; up and down go to the
// next row shown, passing over empty ones, and stop at the edges.
@(test)
loadout_cursor_wraps_along_rows_and_stops_at_edges :: proc(t: ^testing.T) {
	b: loadout.Loadout_Board
	b.width = {.Fresh = 0, .Slots = 3, .Spare = 2, .Ready = 1}
	b.row = .Slots
	loadout.loadout_move(&b, {.Left})
	testing.expect_value(t, b.col, 2)
	loadout.loadout_move(&b, {.Right})
	testing.expect_value(t, b.col, 0)
	loadout.loadout_move(&b, {.Up}) // the NEW row is empty: stays
	testing.expect_value(t, b.row, loadout.Loadout_Row.Slots)
	b.col = 2
	loadout.loadout_move(&b, {.Down}) // onto the last of two cells
	testing.expect_value(t, b.row, loadout.Loadout_Row.Spare)
	testing.expect_value(t, b.col, 1)
	loadout.loadout_move(&b, {.Left})
	loadout.loadout_move(&b, {.Left})
	testing.expect_value(t, b.col, 1)
	loadout.loadout_move(&b, {.Down})
	loadout.loadout_move(&b, {.Down})
	testing.expect_value(t, b.row, loadout.Loadout_Row.Ready)
	testing.expect_value(t, b.col, 0)
}

// With a slot to spare, the one new weapon goes into a free slot and the
// cursor starts on READY. Fire Air on the empty slot is refused and picks
// nothing up. While the screen is open the session is frozen for the
// presentation.
@(test)
loadout_refuses_an_empty_slot :: proc(t: ^testing.T) {
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := cw_session(cw_two_level_defs(true), session_mods(false, true))
	for i := 0; i < 10_000 && !loadout.loadout_open(s); i += 1 {
		testing.expect(t, !sim.session_frozen(s))
		sim.session_step(s, {})
	}
	if !testing.expect(t, loadout.loadout_open(s), "the loadout screen must open on level 2") {
		return
	}
	testing.expect(t, sim.session_frozen(s), "the loadout screen must freeze the presentation")
	b := &loadout.loadout_of(s).boards[0]
	testing.expect_value(t, b.cells[.Slots][2], sim.NO_WEAPON)
	testing.expect_value(t, b.row, loadout.Loadout_Row.Ready)
	testing.expect(t, loadout.loadout_can_ready(b), "the loadout is as full as two weapons allow")
	cw_press(s, {.Up}) // the spares row is empty: straight to the loadout
	testing.expect_value(t, b.row, loadout.Loadout_Row.Slots)
	cw_press(s, {.Left})
	testing.expect_value(t, b.col, 2)
	sim.session_step(s, {{.Fire_Air}, {}})
	testing.expect(t, cw_sounded(s, sim.SCREEN_SOUND_REFUSE))
	testing.expect(t, !b.holding)
	sim.session_step(s, {})
	cw_press(s, {.Down})
	cw_press(s, {.Fire_Air})
	testing.expect(t, b.ready)
	for i := 0; loadout.loadout_open(s) && i < sim.SCREEN_RESUME_DELAY + 2; i += 1 {
		sim.session_step(s, {})
	}
	testing.expect(t, !loadout.loadout_open(s))
	testing.expect(t, !sim.session_frozen(s))
	testing.expect_value(t, loadout.slots_of(s, 0).loadout, [loadout.LOADOUT_SLOTS]i32{0, 2, sim.NO_WEAPON})
}

// Passives.

// What the passives' shield stage and the core's count of calm do for a
// player in one step, in the order they run.
@(private = "file")
cw_regen_step :: proc(s: ^sim.State, p: sim.Player, time: i32) {
	ps := sim.Player_Step{time = time}
	passives.shield_regen_stage(s, p, &ps)
	player_system.calm_stage(s, p, &ps)
}

// Shield Regen never fills past full, and a ship at full is not shown
// refilling; nor is one in a session without the passives at all.
@(test)
shields_stop_refilling_at_full :: proc(t: ^testing.T) {
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := cw_session(cw_two_level_defs(), session_mods(true, false))
	p := sim.player_at(s, 0)
	p.state = .Playing
	p.shields = 100
	passives.levels_of(s, 0)^[.Shield_Regen] = 3 // no wait, 2% a second
	for i in i32(0) ..< 60 {
		cw_regen_step(s, p, i)
	}
	testing.expect_value(t, p.shields, 100)
	testing.expect(t, !passives.player_regenerating(s, p))
	p.shields = 99
	testing.expect(t, passives.player_regenerating(s, p))
	for i in i32(0) ..< 30 {
		cw_regen_step(s, p, i)
	}
	testing.expect_value(t, p.shields, 100)

	classic := cw_session(cw_two_level_defs())
	q := sim.player_at(classic, 0)
	q.state = .Playing
	q.shields = 50
	testing.expect(t, !passives.player_regenerating(classic, q))
}

// Pure weapon mechanics.

// The Discharge Beam leaves from the weapon's first spawn (its muzzle
// flash), or from the ship itself for a weapon that lists none.
@(test)
beam_leaves_from_the_muzzle :: proc(t: ^testing.T) {
	wd: sim.Weapon
	at := sim.Vec{100, 200}
	testing.expect_value(t, weapon_system.beam_origin(&wd, at), at)
	wd.spawns = []sim.Wep_Spawn_Def{{x_loc = 1, y_loc = -8}}
	testing.expect_value(t, weapon_system.beam_origin(&wd, at), sim.Vec{101, 192})
}

// A target exactly as fast as the shot: the quadratic falls to a line. One
// coming at the shooter is met where both have travelled the same time;
// one running away can never be caught, and is aimed at directly.
@(test)
aimed_shots_meet_a_target_as_fast_as_they_are :: proc(t: ^testing.T) {
	testing.expect_value(t, weapon_system.aimed_intercept({0, -100}, {0, 10}, 10), sim.Vec{0, -50})
	testing.expect_value(t, weapon_system.aimed_intercept({0, -100}, {0, -10}, 10), sim.Vec{0, -100})
}

// Against the shipped weapons.

@(private = "file")
Assets_Fixture :: struct {
	arena: vmem.Arena,
	defs:  sim.Defs,
	s:     ^sim.State,
}

// Stage 1 in a New Weapons session (and Easy Mode's passives with `easy`),
// once the ship is in play. The caller sets context.allocator to the arena.
@(private = "file")
cw_assets_fixture :: proc(t: ^testing.T, f: ^Assets_Fixture, easy: bool) -> bool {
	if !os.exists("assets/data/index.json") || !os.exists("assets/extra") {
		log.info("skipped: needs the extracted assets tree")
		return false
	}
	testing.expect(t, vmem.arena_init_growing(&f.arena) == nil)
	alloc := vmem.arena_allocator(&f.arena)
	context.allocator = alloc
	f.defs, _ = data.assets_defs_load("assets", alloc)
	if _, ok := data.extra_defs_load("assets", &f.defs, alloc); !testing.expect(t, ok) {
		return false
	}
	f.s = new(sim.State)
	sim.init(f.s, sim.Session{seed = 1, level_id = f.defs.levels[0].id, game_type = .Single, mods = session_mods(easy, true)}, &f.defs)
	for i := 0; i < 300 && sim.player_at(f.s, 0).state != .Playing; i += 1 {
		sim.session_step(f.s, {})
	}
	return testing.expect(t, sim.player_at(f.s, 0).state == .Playing, "the ship must be in play")
}

@(private = "file")
cw_weapon :: proc(t: ^testing.T, d: ^sim.Defs, id: sim.Res_ID) -> i32 {
	for &w, i in d.weapons {
		if w.id == id {
			return i32(i)
		}
	}
	testing.expectf(t, false, "no weapon %v in the data", id)
	return sim.NO_WEAPON
}

// Player 1 flies `w`, as a loadout holding it would.
@(private = "file")
cw_fly :: proc(s: ^sim.State, w: i32) {
	loadout.slots_of(s, 0).loadout[0] = w
	weapon_system.change_weapon(s, sim.player_at(s, 0).weapons, sim.WEP_AIR, w)
}

// Entities of unit `id` not in `seen` yet: counted, noted, and their
// indices appended to `out`.
@(private = "file")
cw_new_of :: proc(s: ^sim.State, seen: ^map[i32]bool, id: sim.Res_ID, out: ^[dynamic]i32 = nil) -> (n: int) {
	ui := sim.unit_index(s.defs, id)
	for used, i in sim.single(s, sim.Pool).entity_used {
		e := sim.entity_at(s, i32(i))
		if !used || e.unit != ui || e.number in seen {
			continue
		}
		seen[e.number] = true
		n += 1
		if out != nil {
			append(out, i32(i))
		}
	}
	return
}

// A stationary mine at `loc` with `shields`, hittable at once.
@(private = "file")
cw_mine :: proc(t: ^testing.T, s: ^sim.State, loc: sim.Vec, shields: f32) -> sim.Entity {
	req := sim.spawn_request(sim.res_id("mine"))
	req.loc = loc
	req.stationary = true
	r := lifecycle.eg_request_spawn(s, req)
	if !testing.expect(t, sim.ref_valid(s, r), "the mine must spawn") {
		return {}
	}
	e := sim.entity_at(s, r.index)
	e.loc = loc // the unit spawns at a random offset
	e.appear_delay = 0
	e.shields = shields
	return e
}

// The Bacta Gun lists its seven-shot fan out of order (3, 6, 9, then -3,
// -6, -9, then 0, each shot's heading its offset). Weapon 2's two extra
// lanes at level 2 continue the fan one step out each side: nine shots, 3
// apart from -12 to 12, each turned by its offset, in order across it. The
// muzzle flash fires as it is.
@(test)
bacta_gun_extra_lanes_continue_its_fan :: proc(t: ^testing.T) {
	f: Assets_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !cw_assets_fixture(t, &f, true) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	bg := cw_weapon(t, &f.defs, passives.WEAPON_BACTA_GUN)
	if bg == sim.NO_WEAPON {
		return
	}
	passives.levels_of(s, 0)^[.Weapon_2] = 2
	out: [stats.MAX_LANES + stats.MAX_EXTRA_SPAWNS]stats.Weapon_Spawn
	n := stats.weapon_spawns(s, bg, 0, false, out[:])
	shots, flashes := 0, 0
	for sp in out[:n] {
		if sp.unit == sim.res_id("bagb") {
			x := i32(-12 + 3 * shots)
			testing.expectf(t, sp.x == x, "shot %d at %d, want %d", shots, sp.x, x)
			testing.expectf(t, sp.set_heading && sp.angle == stats.wrap_angle(x), "shot %d heads %d, want %d", shots, sp.angle, stats.wrap_angle(x))
			shots += 1
		} else if sp.unit == sim.res_id("bagl") {
			flashes += 1
		}
	}
	testing.expect_value(t, shots, 9)
	testing.expect_value(t, flashes, 1)
}

// An extra volley from a direct-fire weapon (one whose spawn list holds its
// shots) comes VOLLEY_INTERVAL steps after the shot that owes it. No shipped
// weapon with an extra-volley passive fires directly (the Rear Gun and
// Photon Beam fire spawners), so in this test's own Defs the Rear Gun is
// given the Ion Cannon's spawn list; Weapon 3 at level 3 owes one volley.
@(test)
direct_fire_extra_volley_follows_two_steps_later :: proc(t: ^testing.T) {
	f: Assets_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !cw_assets_fixture(t, &f, true) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	rg := cw_weapon(t, &f.defs, passives.WEAPON_REAR_GUN)
	ion := cw_weapon(t, &f.defs, passives.WEAPON_ION_CANNON)
	if rg == sim.NO_WEAPON || ion == sim.NO_WEAPON {
		return
	}
	f.defs.weapons[rg].spawns = f.defs.weapons[ion].spawns
	passives.levels_of(s, 0)^[.Weapon_3] = 3
	cw_fly(s, rg)
	shot := sim.res_id("icb ")
	seen := make(map[i32]bool)
	cw_new_of(s, &seen, shot)
	got: [6]int
	for i in 0 ..< len(got) {
		sim.session_step(s, {i == 0 ? {.Fire_Air} : {}, {}})
		got[i] = cw_new_of(s, &seen, shot)
	}
	testing.expect_value(t, got, [6]int{2, 0, 2, 0, 0, 0})
}

// A spawner weapon's extra volley comes from its spawner, which lives one
// volley period longer: the Photon Beam's spawner, a volley of three every
// two steps, fires three more shots under Weapon 4 at level 3.
@(test)
spawner_extra_volley_is_one_more_volley :: proc(t: ^testing.T) {
	f: Assets_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !cw_assets_fixture(t, &f, true) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	pb := cw_weapon(t, &f.defs, passives.WEAPON_PHOTON_BEAM)
	if pb == sim.NO_WEAPON {
		return
	}
	cw_fly(s, pb)
	bullet := sim.res_id("pbbu")
	seen := make(map[i32]bool)
	volley :: proc(s: ^sim.State, seen: ^map[i32]bool, bullet: sim.Res_ID) -> (n: int) {
		cw_new_of(s, seen, bullet)
		for i in 0 ..< 16 {
			sim.session_step(s, {i == 0 ? {.Fire_Air} : {}, {}})
			n += cw_new_of(s, seen, bullet)
		}
		return
	}
	plain := volley(s, &seen, bullet)
	testing.expect(t, plain > 0 && plain % 3 == 0, "the Photon Beam fires volleys of three")
	passives.levels_of(s, 0)^[.Weapon_4] = 3
	testing.expect_value(t, volley(s, &seen, bullet), plain + 3)
}

// Weapon 1 at level 3: the Ion Cannon's shots leave at half their speed
// and speed up, ACCEL_RATE a step, towards ACCEL_TOP percent of it; with
// level 1's extra lane there are three.
@(test)
ion_cannon_level_3_shots_accelerate :: proc(t: ^testing.T) {
	f: Assets_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !cw_assets_fixture(t, &f, true) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	ion := cw_weapon(t, &f.defs, passives.WEAPON_ION_CANNON)
	if ion == sim.NO_WEAPON {
		return
	}
	cw_fly(s, ion)
	h := sim.player_at(s, 0).weapons
	h.air.pending = 1
	shot := sim.res_id("icb ")
	full := f.defs.units[sim.unit_index(&f.defs, shot)].initial_speed_max
	seen := make(map[i32]bool)
	cw_new_of(s, &seen, shot)
	at := sim.Vec{208, 400}
	plain: [dynamic]i32
	weapon_system.spawn_air(s, h, at)
	cw_new_of(s, &seen, shot, &plain)
	if testing.expect_value(t, len(plain), 2) {
		testing.expect_value(t, sim.speed_from_vector(sim.entity_at(s, plain[0]).vel), full)
	}

	passives.levels_of(s, 0)^[.Weapon_1] = 3
	shaped: [dynamic]i32
	weapon_system.spawn_air(s, h, at)
	cw_new_of(s, &seen, shot, &shaped)
	if !testing.expect_value(t, len(shaped), 3) {
		return
	}
	for i in shaped {
		e := sim.entity_at(s, i)
		testing.expect(t, abs(sim.speed_from_vector(e.vel) - full / 2) < 1e-3, "leaves at half speed")
		testing.expect(t, abs(sim.speed_from_vector(e.vel_target) - full * stats.ACCEL_TOP / 100) < 1e-3, "speeds up to ACCEL_TOP percent")
		testing.expect(t, abs(sim.speed_from_vector(e.vel_delta) - stats.ACCEL_RATE) < 1e-3)
	}
	sim.session_step(s, {})
	e := sim.entity_at(s, shaped[0])
	testing.expect(t, sim.speed_from_vector(e.vel) > full / 2, "a step on, the shot is faster")
}

// powerup_Air_DoReleaseOnMaxPowerLevel: a charge that reaches the top
// releases by itself, with the button still held. No shipped weapon sets
// it, so this test's Defs set it on the Ion Cannon; as shipped, the charge
// holds at the top instead.
@(test)
full_charge_releases_itself_when_the_weapon_says_so :: proc(t: ^testing.T) {
	f: Assets_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !cw_assets_fixture(t, &f, false) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	ion := cw_weapon(t, &f.defs, passives.WEAPON_ION_CANNON)
	h := sim.player_at(s, 0).weapons
	if !testing.expect_value(t, h.air.weapon, ion) {
		return
	}
	top := f.defs.weapons[ion].powerup_air_max_power_level
	for _ in 0 ..< 100 {
		sim.session_step(s, {{.Fire_Air}, {}})
	}
	testing.expect_value(t, h.air_powerup.state, 1)
	testing.expect_value(t, h.air_powerup.level, top)
	for i := 0; i < 100 && h.air_powerup.state != 0; i += 1 {
		sim.session_step(s, {})
	}
	testing.expect_value(t, h.air_powerup.state, 0)

	f.defs.weapons[ion].powerup_air_do_release_on_max_power_level = true
	release := f.defs.weapons[ion].powerup_air_release_spawn
	seen := make(map[i32]bool)
	cw_new_of(s, &seen, release)
	released_at, spawned := -1, 0
	for i in 0 ..< 100 {
		sim.session_step(s, {{.Fire_Air}, {}})
		if released_at < 0 && h.air_powerup.state == 3 {
			released_at = i
			testing.expect_value(t, h.air_powerup.level, top)
			testing.expect_value(t, h.air_powerup.percent, 100)
		}
		spawned += cw_new_of(s, &seen, release)
	}
	// 15 steps to activate, then 3 a level to one past the top.
	testing.expect(t, released_at >= 15 + 3 * int(top) && released_at < 15 + 3 * int(top) + 6, "the charge must release at the top")
	testing.expect(t, spawned > 0, "the release spawns while the button is still held")
}

// The Chaingun's charge, through the fire button: letting go fires one
// aimed pair of rounds for every level the charge held.
@(test)
chaingun_release_fires_a_pair_a_level :: proc(t: ^testing.T) {
	f: Assets_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !cw_assets_fixture(t, &f, false) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	cg := cw_weapon(t, &f.defs, sim.res_id("aicg"))
	if cg == sim.NO_WEAPON {
		return
	}
	cw_fly(s, cg)
	h := sim.player_at(s, 0).weapons
	round := f.defs.weapons[cg].powerup_air_release_spawn
	seen := make(map[i32]bool)
	for _ in 0 ..< 100 {
		sim.session_step(s, {{.Fire_Air}, {}})
	}
	level := h.air_powerup.level
	testing.expect_value(t, level, f.defs.weapons[cg].powerup_air_max_power_level)
	cw_new_of(s, &seen, round)
	rounds := 0
	for _ in 0 ..< 90 {
		sim.session_step(s, {})
		rounds += cw_new_of(s, &seen, round)
	}
	testing.expect_value(t, rounds, 2 * int(level))
	testing.expect_value(t, h.air_powerup.state, 0)
}

// The Chaingun aims only at what is on screen: a nearer enemy above the
// top edge is passed over for one in view.
@(test)
aimed_volley_ignores_enemies_off_screen :: proc(t: ^testing.T) {
	f: Assets_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !cw_assets_fixture(t, &f, false) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	at := sim.Vec{208, 40}
	above := cw_mine(t, s, {208, -20}, 1)
	below := cw_mine(t, s, {208, 240}, 1)
	if above.obj == nil || below.obj == nil {
		return
	}
	found, ok := weapon_system.aimed_target(s, at)
	testing.expect(t, ok && found == below, "the mine in view must be the target")
}

// A pulse spent on a kill goes no further: a target it kills with nothing
// left over stops it there, and the next along the line is untouched.
@(test)
discharge_beam_spent_on_a_kill_stops_there :: proc(t: ^testing.T) {
	f: Assets_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !cw_assets_fixture(t, &f, false) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	db := cw_weapon(t, &f.defs, sim.res_id("aidb"))
	if db == sim.NO_WEAPON {
		return
	}
	wd := &f.defs.weapons[db]
	at := sim.Vec{208, 420}
	near := cw_mine(t, s, at + {0, -80}, 1)
	far := cw_mine(t, s, at + {0, -160}, 1)
	if near.obj == nil || far.obj == nil {
		return
	}
	s.beams.count = 0
	weapon_system.beam_fire(s, sim.player_at(s, 0).weapons, wd, at, 1, wd.beam.width, false, sim.single(s, sim.Clock).time)
	testing.expect(t, near.deleted, "the first target must die")
	testing.expect(t, !far.deleted && far.shields == 1, "nothing is left for the second")
	testing.expect(t, s.beams.count == 1 && s.beams.events[0].to_y == near.loc.y, "the beam stops at the kill")
}

// A beam weapon with no shrapnel: its kills burst, and throw nothing. The
// shipped beam has shrapnel; this test's copy of it has none.
@(test)
discharge_beam_without_shrapnel_throws_none :: proc(t: ^testing.T) {
	f: Assets_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !cw_assets_fixture(t, &f, false) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	db := cw_weapon(t, &f.defs, sim.res_id("aidb"))
	if db == sim.NO_WEAPON {
		return
	}
	wd := f.defs.weapons[db]
	wd.beam.shrapnel_count = 0
	at := sim.Vec{208, 420}
	one := cw_mine(t, s, at + {0, -80}, 1)
	if one.obj == nil {
		return
	}
	seen := make(map[i32]bool)
	cw_new_of(s, &seen, f.defs.weapons[db].beam.shrapnel)
	bursts := s.particles.count
	weapon_system.beam_fire(s, sim.player_at(s, 0).weapons, &wd, at, 2, wd.beam.width, false, sim.single(s, sim.Clock).time)
	testing.expect(t, one.deleted)
	testing.expect(t, s.particles.count > bursts, "the kill still bursts")
	testing.expect_value(t, cw_new_of(s, &seen, f.defs.weapons[db].beam.shrapnel), 0)
}

// Priv_Spawn_Ground spawns the weapon's crosshair spawn at the crosshair
// as well as its bombs. No shipped ground weapon has one; this test's Defs
// give the Plasma Bomb its launch flash there.
@(test)
ground_weapon_spawns_at_the_crosshair :: proc(t: ^testing.T) {
	f: Assets_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !cw_assets_fixture(t, &f, false) {
		return
	}
	context.allocator = vmem.arena_allocator(&f.arena)
	s := f.s
	bomb := cw_weapon(t, &f.defs, passives.WEAPON_PLASMA_BOMB)
	h := sim.player_at(s, 0).weapons
	if !testing.expect_value(t, h.ground.weapon, bomb) {
		return
	}
	flash := sim.res_id("pblf")
	at := sim.Vec{208, 400}
	h.loc = at
	h.crosshair.loc = {208, 200}
	seen := make(map[i32]bool)
	cw_new_of(s, &seen, flash)
	weapon_system.spawn_ground(s, h, at)
	testing.expect_value(t, cw_new_of(s, &seen, flash), 1) // the launch flash, at the ship

	f.defs.weapons[bomb].crosshair_spawn_on_activation = flash
	got: [dynamic]i32
	weapon_system.spawn_ground(s, h, at)
	cw_new_of(s, &seen, flash, &got)
	if !testing.expect_value(t, len(got), 2) {
		return
	}
	at_crosshair := 0
	for i in got {
		if e := sim.entity_at(s, i); abs(e.loc.y - h.crosshair.loc.y) < abs(e.loc.y - at.y) {
			at_crosshair += 1
		}
	}
	testing.expect_value(t, at_crosshair, 1)
}
