package tests

import "core:testing"
import "dr:sim"

@(test)
sim_is_deterministic :: proc(t: ^testing.T) {
	session := sim.Session{seed = 0xDEADBEEF, level_id = sim.level_id("le03"), game_type = .Co_Op}
	inputs := make([]sim.Frame_Input, 600)
	defer delete(inputs)

	// Deterministic pseudo-input so the sequence is reproducible.
	r := sim.rand_init(99)
	for i in 0 ..< len(inputs) {
		a := sim.Buttons{}
		if sim.rand_below(&r, 2) == 0 { a += {.Left} }
		if sim.rand_below(&r, 2) == 0 { a += {.Up} }
		if sim.rand_below(&r, 3) == 0 { a += {.Fire_Air} }
		inputs[i] = sim.Frame_Input{a, {}}
	}

	run :: proc(session: sim.Session, inputs: []sim.Frame_Input) -> u64 {
		s: sim.State
		sim.init(&s, session)
		for in_ in inputs {
			sim.step(&s, in_)
		}
		return sim.checksum(&s)
	}

	a := run(session, inputs)
	b := run(session, inputs)
	testing.expect_value(t, a, b)
}

@(test)
different_seeds_diverge :: proc(t: ^testing.T) {
	s1, s2: sim.State
	sim.init(&s1, sim.Session{seed = 1, level_id = sim.level_id("le01"), game_type = .Single})
	sim.init(&s2, sim.Session{seed = 2, level_id = sim.level_id("le01"), game_type = .Single})
	testing.expect(t, sim.checksum(&s1) != sim.checksum(&s2), "seed must affect state")
}

@(test)
rng_is_reproducible :: proc(t: ^testing.T) {
	a := sim.rand_init(12345)
	b := sim.rand_init(12345)
	for _ in 0 ..< 1000 {
		testing.expect_value(t, sim.rand_u32(&a), sim.rand_u32(&b))
	}
}

@(test)
coop_activates_two_players :: proc(t: ^testing.T) {
	s: sim.State
	sim.init(&s, sim.Session{seed = 7, level_id = sim.level_id("le01"), game_type = .Co_Op})
	testing.expect(t, s.players[0].active && s.players[1].active, "co-op needs both players")

	solo: sim.State
	sim.init(&solo, sim.Session{seed = 7, level_id = sim.level_id("le01"), game_type = .Single})
	testing.expect(t, solo.players[0].active && !solo.players[1].active, "single is one player")
}

@(test)
film_replay_matches_live_run :: proc(t: ^testing.T) {
	frames := make([]sim.Frame_Input, 120)
	defer delete(frames)
	for i in 0 ..< len(frames) {
		frames[i] = sim.Frame_Input{{.Right, .Down}, {}}
	}
	film := sim.Film{
		session = sim.Session{seed = 555, level_id = sim.level_id("le02"), game_type = .Single},
		frames  = frames,
	}
	replayed := sim.replay(film)

	live: sim.State
	sim.init(&live, film.session)
	for f in frames {
		sim.step(&live, f)
	}
	testing.expect_value(t, sim.checksum(&replayed), sim.checksum(&live))
}
