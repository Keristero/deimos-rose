package tests

import "core:testing"
import "dr:sim"

// A minimal, synthetic definition set: one empty level and the two player
// definitions. Enough to drive sessions without the original game data.
synthetic_defs :: proc() -> ^sim.Defs {
	d := new(sim.Defs, context.temp_allocator)
	levels := make([]sim.Level_Def, 1, context.temp_allocator)
	levels[0] = {
		id         = sim.level_id("le01"),
		number     = 1,
		background = {top = 0, left = 0, bottom = 3600, right = 480},
	}
	players := make([]sim.Player_Entry, 2, context.temp_allocator)
	for &p, i in players {
		p.id = sim.res_id(i == 0 ? "pl01" : "pl02")
		p.def.entry_solo_start_x = 208
		p.def.entry_solo_start_y = 330
		p.def.entry_initial_delay = 3
		p.def.entry_spawn = sim.NONE
	}
	weapons := make([]sim.Weapon, 2, context.temp_allocator)
	weapons[0] = {id = sim.res_id("wair"), def = {type = sim.WEP_AIR, default = sim.WEP_DEFAULT_AIR, minimum_level_available = 1, maximum_level_available = 12, auto_repeat = true}}
	weapons[1] = {id = sim.res_id("wgnd"), def = {type = sim.WEP_GROUND, default = sim.WEP_DEFAULT_GROUND, minimum_level_available = 1, maximum_level_available = 12}}
	for &w in weapons {
		w.player1_appearance_face = sim.NONE
		w.player2_appearance_face = sim.NONE
		w.crosshair_face = sim.NONE
		w.crosshair_spawn_on_activation = sim.NONE
		w.powerup_air_activation_spawn = sim.NONE
		w.powerup_air_release_spawn = sim.NONE
		w.powerup_ground_activation_spawn = sim.NONE
		w.powerup_ground_release_spawn = sim.NONE
	}
	d.levels = levels
	d.players = players
	d.weapons = weapons
	for &o in d.perm_objects {
		o = sim.NONE
	}
	d.perm_objects[0] = sim.res_id("pl01")
	d.perm_objects[1] = sim.res_id("pl02")
	d.perm_floats[sim.PF_VISIBLE_GAME_WIDTH] = 416
	d.perm_floats[sim.PF_VISIBLE_GAME_HEIGHT] = 480
	d.perm_floats[sim.PF_PLAYER_APPEARS_REQUIRED] = 100
	d.perm_floats[sim.PF_PLAYER_APPEARS_DELTA] = 2
	return d
}

@(test)
sim_is_deterministic :: proc(t: ^testing.T) {
	defs := synthetic_defs()
	session := sim.Session{seed = 0xDEADBEEF, level_id = sim.level_id("le01"), game_type = .Co_Op}
	inputs := make([]sim.Frame_Input, 600, context.temp_allocator)
	r := sim.rand_init(99)
	for i in 0 ..< len(inputs) {
		a := sim.Buttons{}
		if sim.random_int(&r, 0, 1, 0) == 0 { a += {.Left} }
		if sim.random_int(&r, 0, 1, 0) == 0 { a += {.Up} }
		inputs[i] = sim.Frame_Input{a, {}}
	}
	run :: proc(session: sim.Session, defs: ^sim.Defs, inputs: []sim.Frame_Input) -> u64 {
		s := new(sim.State)
		defer free(s)
		sim.init(s, session, defs)
		for in_ in inputs {
			sim.step(s, in_)
		}
		return sim.checksum(s)
	}
	testing.expect_value(t, run(session, defs, inputs), run(session, defs, inputs))
}

@(test)
different_seeds_diverge :: proc(t: ^testing.T) {
	defs := synthetic_defs()
	s1, s2 := new(sim.State), new(sim.State)
	defer free(s1)
	defer free(s2)
	sim.init(s1, sim.Session{seed = 1, level_id = sim.level_id("le01"), game_type = .Single}, defs)
	sim.init(s2, sim.Session{seed = 2, level_id = sim.level_id("le01"), game_type = .Single}, defs)
	testing.expect(t, sim.checksum(s1) != sim.checksum(s2), "seed must affect state")
}

@(test)
coop_activates_two_players :: proc(t: ^testing.T) {
	defs := synthetic_defs()
	s := new(sim.State)
	defer free(s)
	sim.init(s, sim.Session{seed = 7, level_id = sim.level_id("le01"), game_type = .Co_Op}, defs)
	testing.expect(t, s.players[0].active && s.players[1].active, "co-op needs both players")
	sim.init(s, sim.Session{seed = 7, level_id = sim.level_id("le01"), game_type = .Single}, defs)
	testing.expect(t, s.players[0].active && !s.players[1].active, "single is one player")
}

@(test)
players_enter_then_read_the_film :: proc(t: ^testing.T) {
	// Only a player in play reads input, so a film is consumed one frame per
	// step in state 4 -- not one per step (G_Player::Priv_GetInputs).
	defs := synthetic_defs()
	frames := make([]sim.Frame_Input, 10, context.temp_allocator)
	film := sim.Film{session = {seed = 5, level_id = sim.level_id("le01"), game_type = .Single}, frames = frames}
	s := new(sim.State)
	defer free(s)
	sim.init(s, film.session, defs)
	testing.expect_value(t, s.players[0].state, sim.Player_State.Entering)
	for _ in 0 ..< 4 {
		sim.step(s, {}, &film)
	}
	// entry_initial_delay 3: appears once time > 0 + 3, i.e. at time 4.
	testing.expect_value(t, s.film_cursor[0], i32(0))
	sim.step(s, {}, &film)
	testing.expect_value(t, s.players[0].state, sim.Player_State.Playing)
	testing.expect_value(t, s.film_cursor[0], i32(1))

	sim.replay(s, &film, defs)
	// frames + 1 reads: the last one finds the film exhausted.
	testing.expect_value(t, s.film_cursor[0], i32(11))
	testing.expect_value(t, s.unported, sim.Site(0))
}

@(test)
level_start_draws_the_nag_timer :: proc(t: ^testing.T) {
	// G_Player::ResetAtLevelStart always makes one RandomInt(400, 2000).
	defs := synthetic_defs()
	buf: [8]sim.Draw
	log := sim.Draw_Log{draws = buf[:]}
	s := new(sim.State)
	defer free(s)
	sim.init(s, sim.Session{seed = 0x469c2, level_id = sim.level_id("le01"), game_type = .Single}, defs, &log)
	got := sim.draw_log_entries(&log)
	testing.expect_value(t, len(got), 1)
	testing.expect_value(t, got[0], sim.Draw{site = 0x43103a, kind = .Int, a = 400, b = 2000, frame = 0})
}

@(test)
list_cursor_survives_deletion :: proc(t: ^testing.T) {
	// U_LinkedList::DeleteLink steps the cursor back, so iteration continues
	// with the next item.
	links: [5]sim.Link
	l := sim.list_init()
	for i in i32(0) ..< 5 {
		sim.list_append(&l, links[:], i)
	}
	seen: [dynamic]i32
	defer delete(seen)
	c := sim.Cursor{sim.NO_LINK}
	n := l.count
	for _ in 0 ..< n {
		i := sim.list_next(&l, links[:], &c)
		append(&seen, i)
		if i == 0 || i == 2 {
			sim.list_remove(&l, links[:], i, &c)
		}
	}
	testing.expect_value(t, len(seen), 5)
	for v, k in seen {
		testing.expect_value(t, v, i32(k))
	}
	testing.expect_value(t, l.count, i32(3))
	testing.expect_value(t, l.head, i32(1))
}

@(test)
level_end_tally_scores_the_ground_accuracy :: proc(t: ^testing.T) {
	// FUN_00420930: the bonus tier steps down from 100% by whole multiples
	// of perm float 0xbc, and is multiplied by the level number. The
	// countdown step is 2% of the total but never below perm float 0xc7.
	defs := synthetic_defs()
	defs.perm_floats[0xbc] = 5 // the gap between tiers
	tiers := [6]f32{5000, 2000, 1000, 500, 250, 0}
	for v, i in tiers {
		defs.perm_floats[0xbd + i] = v
	}
	defs.perm_floats[0xc7] = 100  // smallest step
	defs.perm_floats[0xc8] = 0.02 // 2% of the bonus per tick
	s := new(sim.State)
	defer free(s)
	sim.init(s, sim.Session{seed = 3, level_id = sim.level_id("le01"), game_type = .Single}, defs)
	s.accuracy_targets, s.accuracy_destroyed = 50, 47 // 94%
	sim.level_end_step(s, s.time)
	testing.expect(t, s.level_ending, "the level must be marked as ending")
	testing.expect_value(t, s.level_end.percent, i32(94))
	// 94% is under 95 but not under 90, so the third tier.
	testing.expect_value(t, s.level_end.bonus, i32(1000))
	testing.expect_value(t, s.level_end.bonus_step, i32(100))
	testing.expect_value(t, s.level_end.state, i32(1))
	testing.expect(t, s.players[0].invulnerable, "players are safe once the level is over")
}

@(test)
level_advance_starts_the_next_level_unfinished :: proc(t: ^testing.T) {
	// Regression: `complete` survived level_advance, so flow_step advanced
	// again on the next step and skipped straight through every level.
	defs := synthetic_defs()
	levels := make([]sim.Level_Def, 3, context.temp_allocator)
	for &l, i in levels {
		l = defs.levels[0]
		l.number = i32(i + 1)
	}
	defs.levels = levels
	s := new(sim.State)
	defer free(s)
	sim.init(s, sim.Session{seed = 3, level_id = sim.level_id("le01"), game_type = .Single}, defs)
	s.level_ending = true
	s.level_end.complete = true
	testing.expect(t, sim.level_advance(s), "level 1 of 3 has a next level")
	testing.expect_value(t, s.level_number, i32(2))
	testing.expect(t, !s.level_end.complete, "the new level must not start already complete")
	testing.expect(t, !s.level_ending, "the new level must not start already ending")
	for _ in 0 ..< 10 {
		sim.step(s, {})
	}
	testing.expect(t, !s.level_end.complete, "a level cannot complete before it scrolls to its end")
	testing.expect_value(t, s.level_number, i32(2))
}

@(test)
money_counter_converts_money_at_the_level_multiplier :: proc(t: ^testing.T) {
	defs := synthetic_defs()
	defs.perm_floats[0xaa] = 0 // do not scale the multiplier by the level
	defs.perm_floats[0xab] = 5
	defs.perm_floats[0xc7] = 1
	defs.perm_floats[0xc8] = 0.02
	s := new(sim.State)
	defer free(s)
	sim.init(s, sim.Session{seed = 3, level_id = sim.level_id("le01"), game_type = .Single}, defs)
	p := &s.players[0]
	p.money = 10
	testing.expect(t, sim.money_counter_start(s, p, s.time, false))
	testing.expect(t, sim.money_counter_active(p))
	testing.expect_value(t, p.counter.value, i32(50))
	testing.expect_value(t, p.counter.step, i32(1)) // 2% of 50, floored at 1
	testing.expect_value(t, p.counter.money, i32(10))
}

// No shipped unit sets entryNotice_STR or destructNotice_STR (see
// sim/notice.odin), so this path never runs against the original's data;
// exercised directly here instead.
@(test)
notice_plays_its_sound_once_the_delay_elapses :: proc(t: ^testing.T) {
	defs := synthetic_defs()
	s := new(sim.State)
	defer free(s)
	sim.init(s, sim.Session{seed = 1, level_id = sim.level_id("le01"), game_type = .Single}, defs)

	u := sim.Unit {
		entry_notice                  = "Test Notice",
		entry_notice_sound            = sim.res_id("snd1"),
		entry_notice_sound_min_volume = 50,
		entry_notice_sound_max_volume = 50,
		entry_notice_delay            = 3,
	}
	sim.notice_request(s, &u, s.time)
	testing.expect_value(t, s.notices.count, 1)
	testing.expect_value(t, s.notices.events[0].text, "Test Notice")

	for _ in 0 ..< 3 {
		s.sounds.count = 0
		sim.notice_process(s)
		testing.expect_value(t, s.sounds.count, 0)
	}
	s.sounds.count = 0
	sim.notice_process(s)
	testing.expect_value(t, s.sounds.count, 1)
	testing.expect_value(t, s.sounds.events[0].id, u.entry_notice_sound)

	// The slot stays busy, so a second request while this one shows is dropped.
	u2 := sim.Unit{entry_notice = "Other", entry_notice_sound = sim.NONE}
	sim.notice_request(s, &u2, s.time)
	testing.expect_value(t, s.notices.count, 1)
}

@(test)
destruct_notice_never_draws_a_sound :: proc(t: ^testing.T) {
	defs := synthetic_defs()
	s := new(sim.State)
	defer free(s)
	sim.init(s, sim.Session{seed = 3, level_id = sim.level_id("le01"), game_type = .Single}, defs)

	sim.notice_request_destruct(s, "Destroyed")
	testing.expect_value(t, s.notices.count, 1)
	for _ in 0 ..< sim.NOTICE_HOLD_FRAMES + 2 {
		sim.notice_process(s)
	}
	testing.expect_value(t, s.sounds.count, 0)
	testing.expect(t, !s.notice.pending, "the slot releases once the hold ends")
}

// The multiplier survives the move to the next level (only a death or a new
// game resets it), and Priv_Appear respawns its icon there: regression for
// the icon, and so the bonus, vanishing at every level change.
@(test)
multiplier_carries_into_the_next_level :: proc(t: ^testing.T) {
	defs := synthetic_defs()
	levels := make([]sim.Level_Def, 2, context.temp_allocator)
	for &l, i in levels {
		l = defs.levels[0]
		l.number = i32(i + 1)
	}
	defs.levels = levels
	x3 := sim.res_id("mul3")
	defs.perm_objects[0x24] = x3
	events := sim.Event_Log{events = make([]sim.Event, 256, context.temp_allocator)}
	s := new(sim.State)
	defer free(s)
	sim.init(s, sim.Session{seed = 3, level_id = sim.level_id("le01"), game_type = .Single}, defs, events = &events)
	p := &s.players[0]
	p.multiplier = 3

	s.level_ending = true
	s.level_end.complete = true
	testing.expect(t, sim.level_advance(s))
	testing.expect_value(t, s.level_number, i32(2))
	testing.expect_value(t, p.multiplier, i32(3))

	events.count = 0
	for _ in 0 ..< 10 {
		sim.step(s, {})
	}
	testing.expect_value(t, p.state, sim.Player_State.Playing)
	spawned := false
	for e in sim.event_log_entries(&events) {
		if e.kind == .Spawn && e.unit == x3 {
			spawned = true
		}
	}
	testing.expect(t, spawned, "entering level 2 at x3 must spawn the x3 icon")
	testing.expect_value(t, p.multiplier, i32(3))
}
