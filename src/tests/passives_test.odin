package tests

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import vmem "core:mem/virtual"

import net "dr:net"
import "dr:data"
import "dr:sim"

// Easy mode's passives and reward screen (sim/passives.odin,
// sim/reward.odin). The rules are the design's (notes/passive-upgrades-and-
// easy-mode.md); these pin how they were read, see docs/passive-upgrades.md.

@(test)
mod_value_takes_the_level_held_and_x_inherits :: proc(t: ^testing.T) {
	m := sim.Mod{.Charge_Rate, .Increase, {10, sim.X, 30}}
	cases := [4]struct{ level: u8, v: i16, ok: bool }{{0, 0, false}, {1, 10, true}, {2, 10, true}, {3, 30, true}}
	for c in cases {
		v, ok := sim.mod_value(m, c.level)
		testing.expectf(t, v == c.v && ok == c.ok, "level %d: got (%d, %v), want (%d, %v)", c.level, v, ok, c.v, c.ok)
	}
	// A stat that is x up to the level held is not touched at all.
	late := sim.Mod{.Risky_Reward, .Enables, {sim.X, 1, sim.X}}
	_, ok := sim.mod_value(late, 1)
	testing.expect(t, !ok, "an x first level must leave the stat alone")
}

@(test)
stat_totals_sum_across_passives :: proc(t: ^testing.T) {
	lv: sim.Passive_Levels
	lv[.Improved_Charge] = 2 // Charge_Rate +20, Maximum_Charge +20
	lv[.Auto_Charge] = 1     // Charge_Rate -50
	testing.expect_value(t, sim.stat_total(&lv, .Charge_Rate, sim.NONE).percent, -30)
	testing.expect_value(t, sim.stat_total(&lv, .Maximum_Charge, sim.NONE).percent, 20)
	testing.expect(t, sim.stat_total(&lv, .Auto_Charge_Air_To_Air, sim.NONE).enabled)
	testing.expect(t, !sim.stat_total(&lv, .Prevent_Overheat, sim.NONE).enabled, "level 2's switch is not on at level 1")
	lv[.Auto_Charge] = 2
	testing.expect(t, sim.stat_total(&lv, .Prevent_Overheat, sim.NONE).enabled)
	testing.expect_value(t, sim.stat_total(&lv, .Charge_Rate, sim.NONE).percent, -30) // level 2 is x: still -50

	lv[.Shield_Regen] = 3
	testing.expect_value(t, sim.stat_total(&lv, .Recharge_Delay, sim.NONE).extra, 0)
	testing.expect_value(t, sim.stat_total(&lv, .Shield_Regen_Rate, sim.NONE).extra, 2)
}

@(test)
weapon_passives_count_only_for_their_weapon :: proc(t: ^testing.T) {
	lv: sim.Passive_Levels
	lv[.Weapon_1] = 1 // Ion Cannon: +1 projectile
	lv[.Weapon_2] = 2 // Bacta Gun: +2 projectiles
	testing.expect_value(t, sim.stat_total(&lv, .Extra_Projectiles, sim.WEAPON_ION_CANNON).extra, 1)
	testing.expect_value(t, sim.stat_total(&lv, .Extra_Projectiles, sim.WEAPON_BACTA_GUN).extra, 2)
	testing.expect_value(t, sim.stat_total(&lv, .Extra_Projectiles, sim.WEAPON_PHOTON_BEAM).extra, 0)
	testing.expect_value(t, sim.stat_total(&lv, .Extra_Projectiles, sim.NONE).extra, 0)
	// Weapon 3's level 3 adds a volley and side fire to levels 1-2's delay.
	lv[.Weapon_3] = 3
	testing.expect_value(t, sim.stat_total(&lv, .Extra_Volley, sim.WEAPON_REAR_GUN).extra, 1)
	testing.expect_value(t, sim.stat_total(&lv, .Firing_Delay, sim.WEAPON_REAR_GUN).percent, -20)
	testing.expect(t, sim.stat_total(&lv, .Side_Firing_Volley, sim.WEAPON_REAR_GUN).enabled)
}

@(test)
scale_rounds_halves_up_and_leaves_zero_exact :: proc(t: ^testing.T) {
	testing.expect_value(t, sim.scale_i32(7, 0), 7)
	testing.expect_value(t, sim.scale_i32(10, 10), 11)
	testing.expect_value(t, sim.scale_i32(5, -50), 3)  // 2.5 rounds up
	testing.expect_value(t, sim.scale_i32(3, -50), 2)  // 1.5 rounds up
	testing.expect_value(t, sim.scale_i32(9, -200), 0) // never below zero
	testing.expect_value(t, sim.scale_i32(-5, 50), -8) // -7.5, away from zero
	testing.expect_value(t, sim.scale_f32(2, 50), 3)
}

@(test)
extra_lanes_continue_the_spread :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, name: string, base: []sim.Lane, extra: i32, want: []f32) {
		out: [sim.MAX_LANES]sim.Lane
		n := sim.lanes_extend(base, extra, out[:])
		if !testing.expectf(t, n == len(want), "%s: %d lanes, want %d", name, n, len(want)) {
			return
		}
		for w, i in want {
			testing.expectf(t, out[i].x == w, "%s: lane %d at %v, want %v", name, i, out[i].x, w)
		}
	}
	// The Ion Cannon's two lanes, +2: one more each side at the same spacing.
	ion := []sim.Lane{{x = -5, src = 0}, {x = 4, src = 1}}
	check(t, "ion +2", ion, 2, {-14, -5, 4, 13})
	// The Photon Beam's three, +3 (odd): shifted half a step, still symmetric.
	photon := []sim.Lane{{x = -6, src = 0}, {x = 0, src = 1}, {x = 6, src = 2}}
	check(t, "photon +3", photon, 3, {-15, -9, -3, 3, 9, 15})
	// A lone lane spreads by LANE_SPACING.
	check(t, "single +1", []sim.Lane{{x = 0}}, 1, {-6, 6})
	check(t, "none", ion, 0, {-5, 4})

	// Headings carry on the same way, and each lane takes its nearest
	// original's unit.
	fan := []sim.Lane{{angle = -10, src = 0}, {angle = 10, src = 1}}
	out: [sim.MAX_LANES]sim.Lane
	n := sim.lanes_extend(fan, 2, out[:])
	testing.expect_value(t, n, 4)
	testing.expect_value(t, out[0].angle, -30)
	testing.expect_value(t, out[3].angle, 30)
	testing.expect_value(t, out[0].src, 0)
	testing.expect_value(t, out[3].src, 1)
}

// Two short levels of the synthetic fixture: long enough to finish, short
// enough to finish fast.
@(private = "file")
two_level_defs :: proc(levels_n := 2) -> ^sim.Defs {
	defs := synthetic_defs()
	levels := make([]sim.Level_Def, levels_n, context.temp_allocator)
	for &l, i in levels {
		l = defs.levels[0]
		l.id = sim.level_id(i == 0 ? "le01" : i == 1 ? "le02" : "le03")
		l.number = i32(i + 1)
		l.background.bottom = 700
	}
	defs.levels = levels
	defs.perm_floats[0x20] = 30 // steps a second
	return defs
}

// Steps with no input until the reward screen opens or the level changes.
@(private = "file")
play_to_level_end :: proc(s: ^sim.State) -> sim.Level_Transition {
	for _ in 0 ..< 10_000 {
		if tr := sim.session_step(s, {}); tr != .None || sim.single(s, sim.Reward).active {
			return tr
		}
	}
	return .None
}

@(private = "file")
sounded :: proc(s: ^sim.State, id: sim.Res_ID) -> bool {
	for e in s.sounds.events[:s.sounds.count] {
		if e.id == id {
			return true
		}
	}
	return false
}

@(test)
no_reward_screen_outside_easy_mode :: proc(t: ^testing.T) {
	defs := two_level_defs()
	s := new(sim.State, context.temp_allocator)
	defer sim.destroy(s)
	sim.init(s, sim.Session{seed = 3, level_id = defs.levels[0].id, game_type = .Co_Op}, defs)
	testing.expect_value(t, play_to_level_end(s), sim.Level_Transition.Advanced)
	testing.expect(t, !sim.single(s, sim.Reward).active)
	testing.expect_value(t, sim.single(s, sim.Level_Info).number, 2)
}

@(test)
reward_screen_takes_every_players_choice :: proc(t: ^testing.T) {
	defs := two_level_defs()
	s := new(sim.State, context.temp_allocator)
	defer sim.destroy(s)
	sim.init(s, sim.Session{seed = 3, level_id = defs.levels[0].id, game_type = .Co_Op, easy = true}, defs)
	testing.expect_value(t, play_to_level_end(s), sim.Level_Transition.None)
	rw := sim.single(s, sim.Reward)
	if !testing.expect(t, rw.active, "the reward screen must open after the tally") {
		return
	}
	// Two choosers: three options, none repeated. The fixture's weapons are
	// not the passives' weapons, so only the four ship passives can come up.
	testing.expect_value(t, rw.count, 3)
	for k in 0 ..< rw.count {
		testing.expect(t, sim.PASSIVES[rw.options[k]].weapon == sim.NONE)
		for j in 0 ..< k {
			testing.expect(t, rw.options[j] != rw.options[k], "an option offered twice")
		}
	}
	testing.expect_value(t, rw.cursor[0], 0)
	testing.expect_value(t, rw.cursor[1], 2)

	time, frame := sim.single(s, sim.Clock).time, sim.frame_of(s)
	press :: proc(s: ^sim.State, a, b: sim.Buttons) -> sim.Level_Transition {
		tr := sim.session_step(s, {a, b})
		if tr == .None && sim.single(s, sim.Reward).active {
			tr = sim.session_step(s, {}) // let go, for the next press edge
		}
		return tr
	}
	// Player 1 moves right and locks; player 2 cannot lock the same option.
	testing.expect_value(t, sim.session_step(s, {{.Right}, {}}), sim.Level_Transition.None)
	testing.expect(t, sounded(s, sim.REWARD_SOUND_MOVE))
	sim.session_step(s, {})
	press(s, {.Fire_Air}, {.Left})
	testing.expect(t, rw.locked[0])
	testing.expect_value(t, rw.cursor[1], 1)
	testing.expect(t, !sim.reward_selectable(s, 1, 1))
	testing.expect_value(t, sim.session_step(s, {{}, {.Fire_Air}}), sim.Level_Transition.None)
	testing.expect(t, sounded(s, sim.REWARD_SOUND_REFUSE))
	testing.expect(t, !rw.locked[1])
	sim.session_step(s, {})
	// Player 1 takes it back and moves on; now player 2 may have it.
	press(s, {.Fire_Ground}, {})
	testing.expect(t, !rw.locked[0])
	press(s, {.Left}, {.Fire_Air})
	testing.expect(t, rw.locked[1])
	testing.expect_value(t, rw.cursor[0], 0)
	// Left from the first option wraps to the last.
	press(s, {.Left}, {})
	testing.expect_value(t, rw.cursor[0], 2)
	want0, want1 := rw.options[2], rw.options[1]
	testing.expect_value(t, sim.single(s, sim.Clock).time, time) // the game stands still
	testing.expect(t, sim.frame_of(s) > frame, "the frame count still moves")

	tr := press(s, {.Fire_Air}, {})
	for i := 0; tr == .None && i < sim.REWARD_RESUME_DELAY + 2; i += 1 {
		testing.expect(t, rw.active, "the screen closed before the resume delay")
		tr = sim.session_step(s, {})
	}
	testing.expect_value(t, tr, sim.Level_Transition.Advanced)
	testing.expect(t, !rw.active)
	testing.expect_value(t, sim.single(s, sim.Level_Info).number, 2)
	testing.expect_value(t, s.players[0].passives[want0], 1)
	testing.expect_value(t, s.players[1].passives[want1], 1)
	total := 0
	for p in s.players {
		for lv in p.passives {
			total += int(lv)
		}
	}
	testing.expect_value(t, total, 2)
}

@(test)
no_reward_screen_after_the_last_level :: proc(t: ^testing.T) {
	defs := two_level_defs(1)
	s := new(sim.State, context.temp_allocator)
	defer sim.destroy(s)
	sim.init(s, sim.Session{seed = 3, level_id = defs.levels[0].id, game_type = .Single, easy = true}, defs)
	testing.expect_value(t, play_to_level_end(s), sim.Level_Transition.All_Complete)
	testing.expect(t, !sim.single(s, sim.Reward).active)
}

@(test)
reward_options_are_one_more_than_the_players :: proc(t: ^testing.T) {
	defs := two_level_defs()
	s := new(sim.State, context.temp_allocator)
	defer sim.destroy(s)
	sim.init(s, sim.Session{seed = 11, level_id = defs.levels[0].id, game_type = .Single, easy = true}, defs)
	play_to_level_end(s)
	testing.expect(t, sim.single(s, sim.Reward).active)
	testing.expect_value(t, sim.single(s, sim.Reward).count, 2)
	testing.expect(t, !sim.single(s, sim.Reward).choosing[1], "an absent player does not choose")
	// A passive already at its top level for the only chooser is not offered.
	sim.init(s, sim.Session{seed = 11, level_id = defs.levels[0].id, game_type = .Single, easy = true}, defs)
	s.players[0].passives = #partial {.Improved_Manoeuvring = 2, .Auto_Charge = 2, .Improved_Charge = 3}
	play_to_level_end(s)
	testing.expect_value(t, sim.single(s, sim.Reward).count, 1)
	testing.expect_value(t, sim.single(s, sim.Reward).options[0], sim.Passive.Shield_Regen)
}

@(test)
shields_regenerate_after_the_recharge_delay :: proc(t: ^testing.T) {
	defs := two_level_defs()
	s := new(sim.State, context.temp_allocator)
	defer sim.destroy(s)
	sim.init(s, sim.Session{seed = 1, level_id = defs.levels[0].id, game_type = .Single, easy = true}, defs)
	p := &s.players[0]
	p.state = .Playing
	p.shields = 50
	p.passives[.Shield_Regen] = 1 // after 30 s, 1% a second
	sim.player_regen_interrupt(p)
	for i in 0 ..< i32(30 * 30) {
		sim.player_passives_process(s, p, i)
	}
	testing.expect_value(t, p.shields, 50)
	testing.expect(t, sim.player_regenerating(s, p))
	for i in 0 ..< i32(30) {
		sim.player_passives_process(s, p, i)
	}
	testing.expect_value(t, p.shields, 51)
	// Damage starts the wait again.
	sim.player_regen_interrupt(p)
	testing.expect(t, !sim.player_regenerating(s, p))
	// Level 3: no wait, 2% a second.
	p.passives[.Shield_Regen] = 3
	for i in 0 ..< i32(15) {
		sim.player_passives_process(s, p, i)
	}
	testing.expect_value(t, p.shields, 52)
}

// The level-change convergence test (rollback_session_test.odin) in easy
// mode: the reward screen is stepped, snapshotted and rolled back with the
// rest of the session, so two peers choosing under latency and loss must
// come out with the same choices on the same frame.
@(test)
rollback_session_converges_through_the_reward_screen :: proc(t: ^testing.T) {
	defs := two_level_defs(3)
	session := sim.Session{seed = 0xEA5E, level_id = defs.levels[0].id, game_type = .Co_Op, easy = true}

	FRAMES :: 1400
	LATENCY :: 6
	WINDOW :: 8
	inputs := [2][]sim.Buttons{make([]sim.Buttons, FRAMES, context.temp_allocator), make([]sim.Buttons, FRAMES, context.temp_allocator)}
	r := sim.rand_init(91)
	for i in 0 ..< FRAMES {
		for p in 0 ..< 2 {
			b: sim.Buttons
			if sim.random_int(&r, 0, 2, 0) == 0 { b += {p == 0 ? .Left : .Right} }
			if sim.random_int(&r, 0, 3, 0) == 0 { b += {.Fire_Air} }
			if sim.random_int(&r, 0, 12, 0) == 0 { b += {.Fire_Ground} }
			inputs[p][i] = b
		}
	}

	states := [2]^sim.State{new(sim.State, context.temp_allocator), new(sim.State, context.temp_allocator)}
	defer for st in states { sim.destroy(st) }
	rs: [2]net.Rollback_Session
	for p in 0 ..< 2 {
		sim.init(states[p], session, defs)
		net.rollback_session_init(&rs[p], states[p], p, context.temp_allocator)
	}
	defer for p in 0 ..< 2 { net.rollback_session_destroy(&rs[p], context.temp_allocator) }

	Delivery :: struct {
		deliver_at: int,
		pkt:        net.Input_Packet,
	}
	queues := [2][dynamic]Delivery{make([dynamic]Delivery, context.temp_allocator), make([dynamic]Delivery, context.temp_allocator)}
	reward_frames := 0
	max_level: i32 = 0

	for i in 0 ..< FRAMES + LATENCY + 1 {
		for p in 0 ..< 2 {
			w := 0
			for d in queues[p] {
				if d.deliver_at <= i {
					net.rollback_session_receive(&rs[p], d.pkt)
				} else {
					queues[p][w] = d
					w += 1
				}
			}
			resize(&queues[p], w)
		}
		if i >= FRAMES {
			continue
		}
		for p in 0 ..< 2 {
			net.rollback_session_advance(&rs[p], inputs[p][i])
			if i % 5 == 4 {
				continue
			}
			win: [WINDOW]sim.Buttons
			start, count := net.rollback_session_local_window(&rs[p], WINDOW, win[:])
			if count > 0 {
				buf: [64]byte
				n := net.encode_input(buf[:], u8(p), start, win[:count])
				pkt, _ := net.decode_input(buf[:n])
				append(&queues[1 - p], Delivery{i + LATENCY, pkt})
			}
		}
		if sim.single(states[0], sim.Reward).active {
			reward_frames += 1
		}
		max_level = max(max_level, sim.single(states[0], sim.Level_Info).number)
	}

	testing.expect(t, rs[0].rollback_count > 0 && rs[1].rollback_count > 0, "test never exercised a rollback")
	testing.expect(t, max_level >= 3, "test never reached the third level")
	testing.expect(t, reward_frames > 0, "test never opened the reward screen")
	for p in 0 ..< 2 {
		taken := 0
		for lv in states[0].players[p].passives {
			taken += int(lv)
		}
		testing.expectf(t, taken == 2, "player %d took %d passives over two reward screens", p + 1, taken)
	}
	testing.expect_value(t, states[0].players[0].passives, states[1].players[0].passives)
	testing.expect_value(t, states[0].players[1].passives, states[1].players[1].passives)
	testing.expect_value(t, sim.single(states[0], sim.Level_Info).number, sim.single(states[1], sim.Level_Info).number)
	testing.expect_value(t, sim.checksum(states[0]), sim.checksum(states[1]))
}

// Against the shipped weapons (src/assets): the lanes the weapon passives
// add, and the backwards plasma bomb. Skipped without the assets tree.
@(test)
weapon_passives_shape_the_real_weapons :: proc(t: ^testing.T) {
	if !os.exists("assets/data/index.json") {
		log.info("skipped: needs the extracted assets tree")
		return
	}
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	defs, _ := data.assets_defs_load("assets", vmem.arena_allocator(&arena))
	if !testing.expect(t, len(defs.levels) > 0, "the level list must load") {
		return
	}
	s := new(sim.State, context.temp_allocator)
	defer sim.destroy(s)
	sim.init(s, sim.Session{seed = 1, level_id = defs.levels[0].id, game_type = .Single, easy = true}, &defs)

	index :: proc(d: ^sim.Defs, id: sim.Res_ID) -> i32 {
		for &w, i in d.weapons {
			if w.id == id {
				return i32(i)
			}
		}
		return -1
	}
	projectiles :: proc(s: ^sim.State, spawns: []sim.Weapon_Spawn) -> (n: int) {
		for sp in spawns {
			ui := sim.unit_index(s.defs, sp.unit)
			if ui >= 0 && s.defs.units[ui].player_projectile {
				n += 1
			}
		}
		return
	}
	out, before: [64]sim.Weapon_Spawn
	p := &s.players[0]

	ion := index(&defs, sim.WEAPON_ION_CANNON)
	if !testing.expect(t, ion >= 0, "no Ion Cannon in the data") {
		return
	}
	nb := sim.weapon_spawns(s, ion, 0, false, before[:])
	// With no passive held, the spawn list is the weapon's own, as it was.
	wd := &defs.weapons[ion]
	k := 0
	for &sp in wd.spawns {
		if sp.unit == sim.NONE {
			continue
		}
		testing.expectf(t, before[k].unit == sp.unit && before[k].x == sp.x_loc && before[k].y == sp.y_loc && before[k].angle == sp.angle,
			"ion spawn %d changed with no passive held", k)
		k += 1
	}
	testing.expect_value(t, nb, k)
	p.passives[.Weapon_1] = 1
	n := sim.weapon_spawns(s, ion, 0, false, out[:])
	testing.expect_value(t, projectiles(s, out[:n]), projectiles(s, before[:nb]) + 1)
	p.passives[.Weapon_1] = 3 // x at levels 2-3: still the one extra
	n = sim.weapon_spawns(s, ion, 0, false, out[:])
	testing.expect_value(t, projectiles(s, out[:n]), projectiles(s, before[:nb]) + 1)

	// The Bacta Gun's passive leaves the Ion Cannon alone.
	p.passives = #partial {.Weapon_2 = 3}
	n = sim.weapon_spawns(s, ion, 0, false, out[:])
	testing.expect_value(t, n, nb)

	// The plasma bomb, backwards: every spawn mirrored behind the ship.
	bomb := index(&defs, sim.WEAPON_PLASMA_BOMB)
	if !testing.expect(t, bomb >= 0, "no Plasma Bomb in the data") {
		return
	}
	p.passives = #partial {.Ground_Variant_1 = 1}
	fwd := sim.weapon_spawns(s, bomb, 0, false, before[:])
	back := sim.weapon_spawns(s, bomb, 0, true, out[:])
	testing.expect_value(t, back, fwd)
	for i in 0 ..< back {
		testing.expect_value(t, out[i].y, -before[i].y)
		testing.expect(t, out[i].set_heading)
		testing.expect_value(t, out[i].angle, (540 - before[i].angle) % 360)
	}
	// Level 3 drops one more bomb.
	p.passives = #partial {.Ground_Variant_1 = 3}
	n = sim.weapon_spawns(s, bomb, 0, true, out[:])
	testing.expect_value(t, projectiles(s, out[:n]), projectiles(s, before[:fwd]) + 1)

	// Every weapon passive is offered only where its weapon flies.
	testing.expect(t, sim.passive_available(&defs, .Weapon_1, 1))
	testing.expect(t, sim.passive_available(&defs, .Ground_Variant_1, i32(len(defs.levels))))
	for pa in sim.Passive {
		w := sim.PASSIVES[pa].weapon
		if w == sim.NONE {
			continue
		}
		testing.expectf(t, index(&defs, w) >= 0, "%v's weapon is not in the data", pa)
	}
}

// Every passive has an icon recipe (tools/icons/passives.json), and the icon
// `mise run assets:icons` makes from it is in the assets tree, under the name
// the reward screen looks for: the sim.Passive in lower case. The recipe
// check needs nothing but the repository; the file check skips without the
// assets tree.
@(test)
every_passive_has_an_icon :: proc(t: ^testing.T) {
	text, err := os.read_entire_file("tools/icons/passives.json", context.temp_allocator)
	if !testing.expectf(t, err == nil, "cannot read the icon recipe: %v", err) {
		return
	}
	Recipe :: struct {
		size:  int,
		icons: []struct {
			name: string,
		},
	}
	recipe: Recipe
	if !testing.expect(t, json.unmarshal(text, &recipe, allocator = context.temp_allocator) == nil, "the icon recipe must parse") {
		return
	}
	testing.expect_value(t, recipe.size, 32)
	assets := os.exists("assets/data/index.json")
	if !assets {
		log.info("icon files not checked: needs the extracted assets tree")
	}
	for pa in sim.Passive {
		name := strings.to_lower(fmt.tprint(pa), context.temp_allocator)
		found := false
		for icon in recipe.icons {
			found ||= icon.name == name
		}
		testing.expectf(t, found, "no icon recipe named %q", name)
		if assets {
			path := fmt.tprintf("assets/icons/passives/%s.png", name)
			testing.expectf(t, os.exists(path), "%s is missing: run mise run assets:icons", path)
		}
	}
}
