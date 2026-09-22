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
	d.levels = levels
	d.players = players
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
