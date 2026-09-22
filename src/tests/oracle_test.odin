package tests

import "core:testing"
import "dr:oracle"
import "dr:sim"

// A hand-written trace in the tools/oracle/trace.py format. Covers: menu lines
// before srand (dropped), another thread (ignored), an equal-bounds call with
// no draw, a float call, and a direct rand() not attributed to a helper.
SAMPLE_TRACE :: `N 11 0x40f000 0 3
D 11
S 11 289218
N 11 0x412345 5 5
N 11 0x412345 -2 7
D 11
D 12
N 12 0x499999 0 1
I 11 0 1
F 11 0x44f61d 3f000000 3fc00000
D 11
I 11 0 2
I 11 1 2
D 11
S 11 7
`

@(test)
trace_parses_films_calls_and_steps :: proc(t: ^testing.T) {
	films, _, err := oracle.trace_parse(SAMPLE_TRACE)
	defer oracle.trace_destroy(films)
	testing.expect_value(t, err, oracle.Trace_Error.None)
	testing.expect_value(t, len(films), 2)

	f := films[0]
	testing.expect_value(t, f.seed, u32(289218))
	testing.expect_value(t, f.steps, u32(2)) // player 1's line does not count
	testing.expect_value(t, len(f.calls), 3) // thread 12's call is ignored
	testing.expect_value(t, f.draws, 3)
	testing.expect_value(t, f.unpaired, 1) // the final bare D

	testing.expect_value(t, f.calls[0], sim.Draw{site = 0x412345, kind = .Int, a = 5, b = 5, frame = 0})
	testing.expect_value(t, i32(f.calls[1].a), i32(-2))
	testing.expect_value(t, f.calls[2].kind, sim.Draw_Kind.Float)
	testing.expect_value(t, transmute(f32)f.calls[2].b, f32(1.5))
	testing.expect_value(t, f.calls[2].frame, u32(1))

	testing.expect_value(t, films[1].seed, u32(7))
}

@(test)
trace_rejects_malformed_lines :: proc(t: ^testing.T) {
	films, line, err := oracle.trace_parse("S 11 1\nN 11 zz 0 1\n")
	defer oracle.trace_destroy(films)
	testing.expect_value(t, err, oracle.Trace_Error.Malformed_Line)
	testing.expect_value(t, line, 2)
}

@(test)
diff_reports_the_first_divergence :: proc(t: ^testing.T) {
	a := sim.Draw{site = 1, a = 0, b = 9}
	b := sim.Draw{site = 2, a = 0, b = 9}
	want := []sim.Draw{a, a, b}

	same := oracle.diff(want, want)
	testing.expect_value(t, same.matched, 3)
	testing.expect(t, same.first == nil)

	bad := oracle.diff(want, []sim.Draw{a, b, b})
	testing.expect_value(t, bad.matched, 1)
	div := bad.first.?
	testing.expect_value(t, div.index, 1)
	testing.expect_value(t, div.want.?, a)
	testing.expect_value(t, div.got.?, b)

	short := oracle.diff(want, []sim.Draw{a})
	testing.expect_value(t, short.matched, 1)
	testing.expect(t, short.first.?.got == nil)

	extra := oracle.diff([]sim.Draw{a}, want)
	testing.expect(t, extra.first.?.want == nil)
}

@(test)
draw_log_records_calls_even_without_a_draw :: proc(t: ^testing.T) {
	buf: [4]sim.Draw
	log := sim.Draw_Log{draws = buf[:], frame = 3}
	r := sim.rand_init(42, &log)
	plain := sim.rand_init(42)

	sim.random_int(&r, 5, 5, 0x10)
	sim.random_int(&r, 10, 20, 0x20)
	sim.random_float(&r, 0.5, 1.5, 0x30)
	sim.random_int(&plain, 10, 20, 0)
	sim.random_float(&plain, 0.5, 1.5, 0)

	// Logging must not change the sequence.
	testing.expect_value(t, r.next, plain.next)

	got := sim.draw_log_entries(&log)
	testing.expect_value(t, len(got), 3)
	testing.expect_value(t, got[0], sim.Draw{site = 0x10, kind = .Int, a = 5, b = 5, frame = 3})
	testing.expect_value(t, got[2].kind, sim.Draw_Kind.Float)
	testing.expect_value(t, transmute(f32)got[2].a, f32(0.5))
}

@(test)
draw_log_overflow_is_counted_not_fatal :: proc(t: ^testing.T) {
	buf: [1]sim.Draw
	log := sim.Draw_Log{draws = buf[:]}
	r := sim.rand_init(1, &log)
	for _ in 0 ..< 3 {
		sim.random_int(&r, 0, 1, 0)
	}
	testing.expect_value(t, log.count, 1)
	testing.expect_value(t, log.dropped, 2)
}

@(test)
film_reads_stamp_draws_with_the_trace_step_number :: proc(t: ^testing.T) {
	// Trace steps count G_Film::GetInputs calls, so the stamp follows film
	// reads, not game steps.
	buf: [4]sim.Draw
	log := sim.Draw_Log{draws = buf[:]}
	frames := make([]sim.Frame_Input, 3, context.temp_allocator)
	film := sim.Film{session = {seed = 1, level_id = sim.level_id("le01"), game_type = .Single}, frames = frames}
	s := new(sim.State)
	defer free(s)
	sim.init(s, film.session, synthetic_defs(), &log)
	for s.film_cursor[0] == 0 {
		sim.step(s, {}, &film)
	}
	testing.expect_value(t, log.frame, u32(1))
}

@(test)
trace_parses_player_snapshots :: proc(t: ^testing.T) {
	// Detail traces carry the player's own state at the top of each step,
	// decoded from the original's offset-by-a-constant storage.
	films, _, err := oracle.trace_parse(
		"S 11 7\n" +
		"E 11 player_process player=0 state=4 x=208.5 y=330 shields=62.5 money=13 " +
		"lives=2 score=4500 mult=3 warned=1\n" +
		"I 11 0 1\n")
	defer oracle.trace_destroy(films)
	testing.expect_value(t, err, oracle.Trace_Error.None)
	testing.expect_value(t, len(films), 1)
	testing.expect_value(t, len(films[0].players), 1)
	p := films[0].players[0]
	testing.expect_value(t, p.player, i32(0))
	testing.expect_value(t, p.state, i32(4))
	testing.expect_value(t, p.loc, sim.Vec{208.5, 330})
	testing.expect_value(t, p.shields, f32(62.5))
	testing.expect_value(t, p.money, i32(13))
	testing.expect_value(t, p.lives, i32(2))
	testing.expect_value(t, p.score, i32(4500))
	testing.expect_value(t, p.mult, i32(3))
	testing.expect(t, p.warned, "the shield warning flag must survive parsing")
	// The snapshot belongs to the step it precedes: no film read yet.
	testing.expect_value(t, p.frame, u32(0))
}
