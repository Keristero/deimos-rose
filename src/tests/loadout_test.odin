package tests

import "core:log"
import "core:math"
import "core:os"
import "core:testing"
import vmem "core:mem/virtual"

import "dr:data"
import "dr:plugins/loadout"
import "dr:sim"

// New Weapons' loadout screen and the Chaingun's aimed charge
// (sim/loadout.odin, sim/aimed.odin). The rules are the design's
// (notes/new-weapons.md); these pin how they were read, see
// docs/new-weapons.md.

// The synthetic fixture over two short levels, with four air weapons: one
// from level 1, three from level 2, the last of them new content.
@(private = "file")
loadout_defs :: proc() -> ^sim.Defs {
	defs := synthetic_defs()
	levels := make([]sim.Level_Def, 2, context.temp_allocator)
	for &l, i in levels {
		l = defs.levels[0]
		l.id = sim.level_id(i == 0 ? "le01" : "le02")
		l.number = i32(i + 1)
		l.background.bottom = 700
	}
	defs.levels = levels
	defs.perm_floats[0x20] = 30 // steps a second
	weapons := make([]sim.Weapon, 5, context.temp_allocator)
	weapons[0] = defs.weapons[0] // wair, level 1
	weapons[1] = defs.weapons[1] // wgnd
	for k in 2 ..< 5 {
		weapons[k] = defs.weapons[0]
		weapons[k].id = sim.res_id(k == 2 ? "wai2" : k == 3 ? "wai3" : "wai4")
		weapons[k].minimum_level_available = 2
	}
	weapons[4].extra = true
	defs.weapons = weapons
	return defs
}

WAIR :: 0
WAI2 :: 2
WAI3 :: 3
WAI4 :: 4

// Steps with no input until the loadout screen opens; false if it never
// does.
@(private = "file")
play_to_loadout :: proc(s: ^sim.State) -> bool {
	for _ in 0 ..< 10_000 {
		sim.session_step(s, {})
		if loadout.loadout_of(s).active {
			return true
		}
	}
	return false
}

// A press for player 1, then letting go, for the next press edge.
@(private = "file")
press :: proc(s: ^sim.State, b: sim.Buttons) {
	sim.session_step(s, {b, {}})
	sim.session_step(s, {})
}

@(test)
classic_selection_never_picks_new_weapons :: proc(t: ^testing.T) {
	defs := loadout_defs()
	// Only the extra weapon unlocks after wai3: the original's order stops there.
	testing.expect(t, sim.best_air_weapon(defs, 2) != WAI4)
	testing.expect(t, sim.level_air_weapon(defs, 2) != WAI4)
	current := defs.weapons[WAIR].id
	for _ in 0 ..< 4 {
		next := sim.next_weapon_of_type(defs, sim.WEP_AIR, current, 2)
		testing.expect(t, next != WAI4, "Change_Air reached a new weapon outside New Weapons")
		current = defs.weapons[next].id
	}
	s := new(sim.State, context.temp_allocator)
	defer sim.destroy(s)
	sim.init(s, sim.Session{seed = 3, level_id = defs.levels[0].id, game_type = .Single}, defs)
	for _ in 0 ..< 10_000 {
		if sim.session_step(s, {}) != .None {
			break
		}
		testing.expect(t, loadout.loadout_of(s) == nil, "a loadout screen outside New Weapons")
	}
	testing.expect_value(t, sim.single(s, sim.Level_Info).number, 2)
}

@(test)
no_loadout_screen_on_the_first_level :: proc(t: ^testing.T) {
	defs := loadout_defs()
	s := new(sim.State, context.temp_allocator)
	defer sim.destroy(s)
	sim.init(s, sim.Session{seed = 3, level_id = defs.levels[0].id, game_type = .Single, mods = session_mods(false, true)}, defs)
	h := sim.player_at(s, 0).weapons
	testing.expect_value(t, loadout.slots_of(s, 0).loadout, [loadout.LOADOUT_SLOTS]i32{WAIR, sim.NO_WEAPON, sim.NO_WEAPON})
	testing.expect_value(t, h.air.weapon, WAIR)
	for _ in 0 ..< 10_000 {
		if sim.session_step(s, {}) != .None {
			break
		}
		testing.expect(t, !loadout.loadout_of(s).active, "a loadout screen on the first level")
	}
	testing.expect_value(t, sim.single(s, sim.Level_Info).number, 2)
}

@(test)
loadout_screen_places_new_weapons :: proc(t: ^testing.T) {
	defs := loadout_defs()
	s := new(sim.State, context.temp_allocator)
	defer sim.destroy(s)
	sim.init(s, sim.Session{seed = 3, level_id = defs.levels[0].id, game_type = .Single, mods = session_mods(false, true)}, defs)
	if !testing.expect(t, play_to_loadout(s), "the loadout screen must open on level 2") {
		return
	}
	testing.expect_value(t, sim.single(s, sim.Level_Info).number, 2)
	testing.expect(t, !loadout.loadout_of(s).choosing[1], "player 2 is not playing")
	b := &loadout.loadout_of(s).boards[0]
	// Two new weapons go straight into the free slots; the third waits.
	testing.expect_value(t, [3]i32{b.cells[.Slots][0], b.cells[.Slots][1], b.cells[.Slots][2]}, [3]i32{WAIR, WAI2, WAI3})
	testing.expect_value(t, b.width[.Fresh], 1)
	testing.expect_value(t, b.cells[.Fresh][0], WAI4)
	testing.expect_value(t, b.width[.Spare], 1)
	testing.expect_value(t, b.row, loadout.Loadout_Row.Fresh)
	testing.expect(t, !loadout.loadout_can_ready(b))

	time := sim.single(s, sim.Clock).time
	// Pick up the new weapon, and a Fire_Ground puts it back.
	press(s, {.Fire_Air})
	testing.expect(t, b.holding)
	press(s, {.Fire_Ground})
	testing.expect(t, !b.holding)
	// READY is refused while the new row has a weapon in it.
	press(s, {.Down})
	press(s, {.Down})
	press(s, {.Down})
	testing.expect_value(t, b.row, loadout.Loadout_Row.Ready)
	press(s, {.Fire_Air})
	testing.expect(t, !b.ready)
	// The new weapon swaps into the first slot; what was there goes to the
	// new row, and from there to the spares.
	press(s, {.Up})
	press(s, {.Up})
	press(s, {.Up})
	testing.expect_value(t, b.row, loadout.Loadout_Row.Fresh)
	press(s, {.Fire_Air})
	press(s, {.Down})
	press(s, {.Fire_Air})
	testing.expect_value(t, b.cells[.Slots][0], WAI4)
	testing.expect_value(t, b.cells[.Fresh][0], WAIR)
	press(s, {.Up})
	press(s, {.Fire_Air})
	press(s, {.Down})
	press(s, {.Down})
	press(s, {.Fire_Air})
	testing.expect_value(t, b.cells[.Spare][0], WAIR)
	testing.expect(t, loadout.loadout_can_ready(b))
	press(s, {.Down})
	press(s, {.Fire_Air})
	testing.expect(t, b.ready)
	// Fire_Ground takes the ready back; ready again.
	press(s, {.Fire_Ground})
	testing.expect(t, !b.ready)
	press(s, {.Fire_Air})
	testing.expect(t, b.ready)
	testing.expect_value(t, sim.single(s, sim.Clock).time, time) // the game stands still

	for i := 0; loadout.loadout_of(s).active && i < sim.SCREEN_RESUME_DELAY + 2; i += 1 {
		sim.session_step(s, {})
	}
	testing.expect(t, !loadout.loadout_of(s).active, "the screen must close once everyone is ready")
	h := sim.player_at(s, 0).weapons
	testing.expect_value(t, loadout.slots_of(s, 0).loadout, [loadout.LOADOUT_SLOTS]i32{WAI4, WAI2, WAI3})
	testing.expect_value(t, loadout.slots_of(s, 0).spare[0], WAIR)
	// The weapon flown went to the spares, so the first slot's is taken up.
	testing.expect_value(t, sim.air_weapon_shown(h), WAI4)
	// The screen is shown once a stage.
	for _ in 0 ..< 200 {
		sim.session_step(s, {})
		testing.expect(t, !loadout.loadout_of(s).active, "the loadout screen opened twice")
	}
}

// The loadout is a mod of its own: without New Weapons it still opens,
// and hands over only the original's weapons.
@(test)
loadout_without_new_weapons_leaves_them_out :: proc(t: ^testing.T) {
	defs := loadout_defs()
	s := new(sim.State, context.temp_allocator)
	defer sim.destroy(s)
	mods := sim.mods_session(sim.mods_with_deps({int(loadout.ID)}))
	sim.init(s, sim.Session{seed = 3, level_id = defs.levels[0].id, game_type = .Single, mods = mods}, defs)
	if !testing.expect(t, play_to_loadout(s), "the loadout screen must open on level 2") {
		return
	}
	b := &loadout.loadout_of(s).boards[0]
	testing.expect_value(t, [3]i32{b.cells[.Slots][0], b.cells[.Slots][1], b.cells[.Slots][2]}, [3]i32{WAIR, WAI2, WAI3})
	testing.expect_value(t, b.width[.Fresh], 0)
}

@(test)
loadout_keeps_the_weapon_flown :: proc(t: ^testing.T) {
	defs := loadout_defs()
	s := new(sim.State, context.temp_allocator)
	defer sim.destroy(s)
	sim.init(s, sim.Session{seed = 3, level_id = defs.levels[0].id, game_type = .Single, mods = session_mods(false, true)}, defs)
	if !testing.expect(t, play_to_loadout(s)) {
		return
	}
	// Put the new weapon over the second slot and ready: the first slot's
	// weapon, flown all along, stays selected rather than the new one.
	b := &loadout.loadout_of(s).boards[0]
	press(s, {.Fire_Air})
	press(s, {.Down})
	press(s, {.Right})
	press(s, {.Fire_Air})
	press(s, {.Up})
	press(s, {.Fire_Air})
	press(s, {.Down})
	press(s, {.Down})
	press(s, {.Fire_Air})
	press(s, {.Down})
	press(s, {.Fire_Air})
	if !testing.expect(t, b.ready) {
		return
	}
	for i := 0; loadout.loadout_of(s).active && i < sim.SCREEN_RESUME_DELAY + 2; i += 1 {
		sim.session_step(s, {})
	}
	h := sim.player_at(s, 0).weapons
	testing.expect_value(t, loadout.slots_of(s, 0).loadout, [loadout.LOADOUT_SLOTS]i32{WAIR, WAI4, WAI3})
	testing.expect_value(t, loadout.slots_of(s, 0).spare[0], WAI2)
	testing.expect_value(t, sim.air_weapon_shown(h), WAIR)
}

@(test)
change_air_cycles_the_loadout :: proc(t: ^testing.T) {
	h: loadout.Loadout_Slots
	h.loadout = {5, sim.NO_WEAPON, 9}
	testing.expect_value(t, loadout.slots_next(&h, 5), 9)
	testing.expect_value(t, loadout.slots_next(&h, 9), 5) // wraps, past the empty slot
	testing.expect_value(t, loadout.slots_next(&h, 7), 5) // not in the loadout: the first
	testing.expect_value(t, loadout.slots_next(&h, sim.NO_WEAPON), 5)
	h.loadout = {5, sim.NO_WEAPON, sim.NO_WEAPON}
	testing.expect_value(t, loadout.slots_next(&h, 5), 5)
}

@(test)
aimed_shots_lead_the_target :: proc(t: ^testing.T) {
	// Standing still: straight at it.
	testing.expect_value(t, sim.aimed_intercept({0, -100}, {}, 10), sim.Vec{0, -100})
	// Crossing: the aim point is where both arrive at once.
	offset, vel, speed := sim.Vec{0, -100}, sim.Vec{4, 0}, f32(10)
	aim := sim.aimed_intercept(offset, vel, speed)
	tt := math.sqrt(aim.x * aim.x + aim.y * aim.y) / speed
	meet := offset + vel * tt
	testing.expect(t, abs(meet.x - aim.x) < 1e-3 && abs(meet.y - aim.y) < 1e-3, "the shot and the target must meet")
	testing.expect(t, aim.x > 0, "a target moving right is led to the right")
	// Coming straight at the shooter: aimed at the same line, nearer.
	aim = sim.aimed_intercept({0, -100}, {0, 5}, 10)
	testing.expect(t, abs(aim.x) < 1e-3 && aim.y > -100 && aim.y < 0)
	// Too fast to catch: straight at it.
	testing.expect_value(t, sim.aimed_intercept({0, -100}, {20, 0}, 10), sim.Vec{0, -100})
}

// Against the shipped content (src/assets and src/assets/extra): the
// Chaingun loads as new content, and a New Weapons session from stage 7
// opens the loadout once the stage's title has gone. Skipped without the
// assets tree.
@(test)
chaingun_loads_as_new_content :: proc(t: ^testing.T) {
	if !os.exists("assets/data/index.json") || !os.exists("assets/extra") {
		log.info("skipped: needs the extracted assets tree")
		return
	}
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	alloc := vmem.arena_allocator(&arena)
	defs, _ := data.assets_defs_load("assets", alloc)
	originals := len(defs.weapons)
	_, ok := data.extra_defs_load("assets", &defs, alloc)
	if !testing.expect(t, ok && len(defs.levels) >= 7, "the extra content must load") {
		return
	}
	cg := -1
	for &w, i in defs.weapons {
		if w.id == sim.res_id("aicg") {
			cg = i
		}
		testing.expect(t, w.extra == (i >= originals), "only the appended weapons are new content")
	}
	if !testing.expect(t, cg >= 0, "no Chaingun in assets/extra") {
		return
	}
	w := &defs.weapons[cg]
	testing.expect(t, w.aimed_release)
	testing.expect_value(t, w.type, sim.WEP_AIR)
	testing.expect_value(t, w.minimum_level_available, 7)
	testing.expect(t, sim.unit_index(&defs, w.powerup_air_release_spawn) >= 0, "the aimed shot's unit must load")
	testing.expect(t, sim.unit_index(&defs, w.spawns[0].unit) >= 0, "the burst's spawner must load")
	for level in i32(1) ..= 12 {
		testing.expect(t, sim.best_air_weapon(&defs, level) != i32(cg))
	}

	s := new(sim.State, context.temp_allocator)
	defer sim.destroy(s)
	sim.init(s, sim.Session{seed = 1, level_id = defs.levels[6].id, game_type = .Single, mods = session_mods(false, true)}, &defs)
	title := sim.single(s, sim.Level_Info).title
	testing.expect(t, sim.ref_valid(s, title), "stage 7 must show its title")
	steps := 0
	for ; steps < 2000 && !loadout.loadout_of(s).active; steps += 1 {
		sim.session_step(s, {})
	}
	if !testing.expect(t, loadout.loadout_of(s).active, "the loadout screen must open") {
		return
	}
	testing.expect(t, !sim.ref_valid(s, title), "the screen must wait for the title")
	testing.expect(t, steps > 30)
	b := &loadout.loadout_of(s).boards[0]
	fresh := b.cells[.Fresh][:b.width[.Fresh]]
	found := false
	for c in fresh {
		found ||= c == i32(cg)
	}
	testing.expect(t, found, "the Chaingun must be handed over on stage 7")
}

// Against the shipped content: a release volley is two shots, side by side,
// flying at where an enemy in the air will be. Skipped without the assets
// tree.
@(test)
aimed_volley_turns_towards_an_air_enemy :: proc(t: ^testing.T) {
	if !os.exists("assets/data/index.json") || !os.exists("assets/extra") {
		log.info("skipped: needs the extracted assets tree")
		return
	}
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	alloc := vmem.arena_allocator(&arena)
	defs, _ := data.assets_defs_load("assets", alloc)
	if _, ok := data.extra_defs_load("assets", &defs, alloc); !testing.expect(t, ok) {
		return
	}
	cg := i32(-1)
	for &w, i in defs.weapons {
		if w.id == sim.res_id("aicg") {
			cg = i32(i)
		}
	}
	if !testing.expect(t, cg >= 0) {
		return
	}
	// Stage 1 once the ship is in play (the mine is spawned only then), and
	// before anything else is in the air.
	s := new(sim.State, context.temp_allocator)
	defer sim.destroy(s)
	sim.init(s, sim.Session{seed = 1, level_id = defs.levels[0].id, game_type = .Single, mods = session_mods(false, true)}, &defs)
	for i := 0; i < 300 && sim.player_at(s, 0).state != .Playing; i += 1 {
		sim.session_step(s, {})
	}
	at := sim.Vec{208, 400}
	req := sim.spawn_request(sim.res_id("mine"))
	req.loc = at + {80, -80} // up and to the right: a heading of 45
	mine := sim.eg_request_spawn(s, req)
	if !testing.expect(t, sim.ref_valid(s, mine), "the mine must spawn") {
		return
	}
	target := sim.entity_at(s, mine.index)
	target.appear_delay = 0
	found, ok := sim.aimed_target(s, at)
	if !testing.expect(t, ok && found == target, "the mine must be the nearest target") {
		return
	}

	shot := sim.unit_index(&defs, defs.weapons[cg].powerup_air_release_spawn)
	before := make(map[i32]bool, context.temp_allocator)
	for used, i in sim.single(s, sim.Pool).entity_used {
		if e := sim.entity_at(s, i32(i)); used && e.unit == shot {
			before[e.number] = true
		}
	}
	sim.aimed_release_spawn(s, sim.player_at(s, 0).weapons.handler, &defs.weapons[cg], at)
	aim := sim.aimed_intercept(target.loc - at, target.vel, defs.units[shot].initial_speed_max)
	want := sim.invert_angle(sim.angle_from_vector(aim))
	testing.expect(t, want > 20 && want < 70, "the aim must be up and to the right")
	shots: [dynamic]sim.Entity
	shots.allocator = context.temp_allocator
	for used, i in sim.single(s, sim.Pool).entity_used {
		if e := sim.entity_at(s, i32(i)); used && e.unit == shot && !before[e.number] {
			append(&shots, e)
		}
	}
	if !testing.expect_value(t, len(shots), 2) {
		return
	}
	for e in shots {
		testing.expect_value(t, e.heading, want)
	}
	// Side by side: the line between them is square to the line of fire.
	d := sim.vector_from_angle(sim.invert_angle(want))
	gap := shots[1].loc - shots[0].loc
	testing.expect(t, abs(gap.x * d.x + gap.y * d.y) < 0.01, "the pair must fly abreast")
	testing.expect(t, abs(math.sqrt(gap.x * gap.x + gap.y * gap.y) - 2 * sim.AIMED_PAIR_OFFSET) < 0.01)
}
