package tests

import "core:testing"

import net "dr:net"
import "dr:plugins/easy_mode"
import "dr:plugins/passives"
import "dr:sim"
import "dr:sim/stats"
import "dr:sim/systems/player_system"

// Easy mode's reward screen (plugins/easy_mode), the passives' shield
// regeneration against the core's calm, and the core's stats mechanics
// that passives drive (sim/stats). The rules are the design's
// (notes/passive-upgrades-and-easy-mode.md); these pin how they were read,
// see docs/passive-upgrades.md. The passives' own tests are the plugin's
// (plugins/passives/tests).

@(test)
scale_rounds_halves_up_and_leaves_zero_exact :: proc(t: ^testing.T) {
	testing.expect_value(t, stats.scale_i32(7, 0), 7)
	testing.expect_value(t, stats.scale_i32(10, 10), 11)
	testing.expect_value(t, stats.scale_i32(5, -50), 3)  // 2.5 rounds up
	testing.expect_value(t, stats.scale_i32(3, -50), 2)  // 1.5 rounds up
	testing.expect_value(t, stats.scale_i32(9, -200), 0) // never below zero
	testing.expect_value(t, stats.scale_i32(-5, 50), -8) // -7.5, away from zero
	testing.expect_value(t, stats.scale_f32(2, 50), 3)
}

@(test)
extra_lanes_continue_the_spread :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, name: string, base: []stats.Lane, extra: i32, want: []f32) {
		out: [stats.MAX_LANES]stats.Lane
		n := stats.lanes_extend(base, extra, out[:])
		if !testing.expectf(t, n == len(want), "%s: %d lanes, want %d", name, n, len(want)) {
			return
		}
		for w, i in want {
			testing.expectf(t, out[i].x == w, "%s: lane %d at %v, want %v", name, i, out[i].x, w)
		}
	}
	// The Ion Cannon's two lanes, +2: one more each side at the same spacing.
	ion := []stats.Lane{{x = -5, src = 0}, {x = 4, src = 1}}
	check(t, "ion +2", ion, 2, {-14, -5, 4, 13})
	// The Photon Beam's three, +3 (odd): shifted half a step, still symmetric.
	photon := []stats.Lane{{x = -6, src = 0}, {x = 0, src = 1}, {x = 6, src = 2}}
	check(t, "photon +3", photon, 3, {-15, -9, -3, 3, 9, 15})
	// A lone lane spreads by LANE_SPACING.
	check(t, "single +1", []stats.Lane{{x = 0}}, 1, {-6, 6})
	check(t, "none", ion, 0, {-5, 4})

	// Headings carry on the same way, and each lane takes its nearest
	// original's unit.
	fan := []stats.Lane{{angle = -10, src = 0}, {angle = 10, src = 1}}
	out: [stats.MAX_LANES]stats.Lane
	n := stats.lanes_extend(fan, 2, out[:])
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
		if tr := sim.session_step(s, {}); tr != .None || easy_mode.reward_open(s) {
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
	testing.expect(t, easy_mode.reward_of(s) == nil, "easy mode's component outside easy mode")
	testing.expect_value(t, sim.single(s, sim.Level_Info).number, 2)
}

@(test)
reward_screen_takes_every_players_choice :: proc(t: ^testing.T) {
	defs := two_level_defs()
	s := new(sim.State, context.temp_allocator)
	defer sim.destroy(s)
	sim.init(s, sim.Session{seed = 3, level_id = defs.levels[0].id, game_type = .Co_Op, mods = session_mods(true, false)}, defs)
	testing.expect_value(t, play_to_level_end(s), sim.Level_Transition.None)
	rw := easy_mode.reward_of(s)
	if !testing.expect(t, rw.active, "the reward screen must open after the tally") {
		return
	}
	// Two choosers: four options, none repeated. The fixture's weapons are
	// not the passives' weapons, so the four ship passives are all there is.
	testing.expect_value(t, rw.count, 4)
	for k in 0 ..< rw.count {
		testing.expect(t, passives.passive_def(rw.options[k]).weapon == sim.NONE)
		for j in 0 ..< k {
			testing.expect(t, rw.options[j] != rw.options[k], "an option offered twice")
		}
	}
	testing.expect_value(t, rw.cursor[0], 0)
	testing.expect_value(t, rw.cursor[1], 3)

	time, frame := sim.single(s, sim.Clock).time, sim.frame_of(s)
	press :: proc(s: ^sim.State, a, b: sim.Buttons) -> sim.Level_Transition {
		tr := sim.session_step(s, {a, b})
		if tr == .None && easy_mode.reward_of(s).active {
			tr = sim.session_step(s, {}) // let go, for the next press edge
		}
		return tr
	}
	// Player 1 moves right and locks; player 2 cannot lock the same option.
	testing.expect_value(t, sim.session_step(s, {{.Right}, {}}), sim.Level_Transition.None)
	testing.expect(t, sounded(s, sim.SCREEN_SOUND_MOVE))
	sim.session_step(s, {})
	press(s, {.Fire_Air}, {.Left})
	testing.expect(t, rw.locked[0])
	press(s, {}, {.Left})
	testing.expect_value(t, rw.cursor[1], 1)
	testing.expect(t, !easy_mode.reward_selectable(s, 1, 1))
	testing.expect_value(t, sim.session_step(s, {{}, {.Fire_Air}}), sim.Level_Transition.None)
	testing.expect(t, sounded(s, sim.SCREEN_SOUND_REFUSE))
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
	testing.expect_value(t, rw.cursor[0], 3)
	want0, want1 := rw.options[3], rw.options[1]
	testing.expect_value(t, sim.single(s, sim.Clock).time, time) // the game stands still
	testing.expect(t, sim.frame_of(s) > frame, "the frame count still moves")

	tr := press(s, {.Fire_Air}, {})
	for i := 0; tr == .None && i < sim.SCREEN_RESUME_DELAY + 2; i += 1 {
		testing.expect(t, rw.active, "the screen closed before the resume delay")
		tr = sim.session_step(s, {})
	}
	testing.expect_value(t, tr, sim.Level_Transition.Advanced)
	testing.expect(t, !rw.active)
	testing.expect_value(t, sim.single(s, sim.Level_Info).number, 2)
	testing.expect_value(t, passives.levels_of(s, 0)^[want0], 1)
	testing.expect_value(t, passives.levels_of(s, 1)^[want1], 1)
	total := 0
	for i in 0 ..< sim.MAX_PLAYERS {
		for lv in passives.levels_of(s, i)^ {
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
	sim.init(s, sim.Session{seed = 3, level_id = defs.levels[0].id, game_type = .Single, mods = session_mods(true, false)}, defs)
	testing.expect_value(t, play_to_level_end(s), sim.Level_Transition.All_Complete)
	testing.expect(t, !easy_mode.reward_of(s).active)
}

@(test)
reward_options_are_two_more_than_the_players :: proc(t: ^testing.T) {
	defs := two_level_defs()
	s := new(sim.State, context.temp_allocator)
	defer sim.destroy(s)
	sim.init(s, sim.Session{seed = 11, level_id = defs.levels[0].id, game_type = .Single, mods = session_mods(true, false)}, defs)
	play_to_level_end(s)
	testing.expect(t, easy_mode.reward_of(s).active)
	testing.expect_value(t, easy_mode.reward_of(s).count, 3)
	testing.expect(t, !easy_mode.reward_of(s).choosing[1], "an absent player does not choose")
	// A passive already at its top level for the only chooser is not offered.
	sim.init(s, sim.Session{seed = 11, level_id = defs.levels[0].id, game_type = .Single, mods = session_mods(true, false)}, defs)
	passives.levels_of(s, 0)^ = {passives.IMPROVED_MANOEUVRING = 2, passives.AUTO_CHARGE = 2, passives.IMPROVED_CHARGE = 3}
	play_to_level_end(s)
	testing.expect_value(t, easy_mode.reward_of(s).count, 1)
	testing.expect_value(t, easy_mode.reward_of(s).options[0], passives.SHIELD_REGEN)
}

// What the passives' shield stage and the core's count of calm do for a
// player in one step, in the order they run.
@(private = "file")
regen_step :: proc(s: ^sim.State, p: sim.Player, time: i32) {
	ps := sim.Player_Step{time = time}
	passives.shield_regen_stage(s, p, &ps)
	player_system.calm_stage(s, p, &ps)
}

@(test)
shields_regenerate_after_the_recharge_delay :: proc(t: ^testing.T) {
	defs := two_level_defs()
	s := new(sim.State, context.temp_allocator)
	defer sim.destroy(s)
	sim.init(s, sim.Session{seed = 1, level_id = defs.levels[0].id, game_type = .Single, mods = session_mods(true, false)}, defs)
	p := sim.player_at(s, 0)
	p.state = .Playing
	p.shields = 50
	passives.levels_of(s, p.number)^[passives.SHIELD_REGEN] = 1 // after 30 s, 1% a second
	p.calm = 0
	for i in 0 ..< i32(30 * 30) {
		regen_step(s, p, i)
	}
	testing.expect_value(t, p.shields, 50)
	testing.expect(t, passives.player_regenerating(s, p))
	for i in 0 ..< i32(30) {
		regen_step(s, p, i)
	}
	testing.expect_value(t, p.shields, 51)
	// Damage starts the wait again.
	p.calm = 0
	testing.expect(t, !passives.player_regenerating(s, p))
	// Level 3: no wait, 2% a second.
	passives.levels_of(s, p.number)^[passives.SHIELD_REGEN] = 3
	for i in 0 ..< i32(15) {
		regen_step(s, p, i)
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
	session := sim.Session{seed = 0xEA5E, level_id = defs.levels[0].id, game_type = .Co_Op, mods = session_mods(true, false)}

	FRAMES :: 1400
	LATENCY :: 6
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

	link := link_make(LATENCY, context.temp_allocator)
	reward_frames := 0
	max_level: i32 = 0

	for i in 0 ..< FRAMES + LATENCY + 1 {
		link_deliver(&link, rs[:], i)
		if i >= FRAMES {
			continue
		}
		for p in 0 ..< 2 {
			net.rollback_session_advance(&rs[p], inputs[p][i])
			// Drop every fifth send, but not the last: nothing sends after
			// it, so each side would end on its own guess at that frame.
			if i % 5 == 4 && i < FRAMES - 1 {
				continue
			}
			link_send(&link, rs[:], p, i)
		}
		if sim.single(states[0], easy_mode.Reward).active {
			reward_frames += 1
		}
		max_level = max(max_level, sim.single(states[0], sim.Level_Info).number)
	}

	testing.expect(t, rs[0].rollback_count > 0 && rs[1].rollback_count > 0, "test never exercised a rollback")
	testing.expect(t, max_level >= 3, "test never reached the third level")
	testing.expect(t, reward_frames > 0, "test never opened the reward screen")
	for p in 0 ..< 2 {
		taken := 0
		for lv in passives.levels_of(states[0], p)^ {
			taken += int(lv)
		}
		testing.expectf(t, taken == 2, "player %d took %d passives over two reward screens", p + 1, taken)
	}
	testing.expect_value(t, passives.levels_of(states[0], 0)^, passives.levels_of(states[1], 0)^)
	testing.expect_value(t, passives.levels_of(states[0], 1)^, passives.levels_of(states[1], 1)^)
	testing.expect_value(t, sim.single(states[0], sim.Level_Info).number, sim.single(states[1], sim.Level_Info).number)
	testing.expect_value(t, sim.checksum(states[0]), sim.checksum(states[1]))
}

