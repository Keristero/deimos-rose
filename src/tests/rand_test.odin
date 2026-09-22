package tests

import "core:testing"
import "dr:sim"

// Reference vectors computed from the decompiled MSL `_rand`/`_srand` and the
// U_Utils helpers. srand(1) reproduces the well-known ANSI C sequence, which is
// an independent check that the recovered constants are right.

@(test)
rand_matches_the_ansi_c_reference_sequence :: proc(t: ^testing.T) {
	r := sim.rand_init(1)
	want := [8]i32{16838, 5758, 10113, 17515, 31051, 5627, 23010, 7419}
	for w in want {
		testing.expect_value(t, sim.rand_next(&r), w)
	}
}

@(test)
rand_matches_for_a_shipped_film_seed :: proc(t: ^testing.T) {
	// Demo 01 records seed 0x469c2.
	r := sim.rand_init(0x0004_69c2)
	want := [6]i32{26662, 28174, 2951, 23987, 25976, 3858}
	for w in want {
		testing.expect_value(t, sim.rand_next(&r), w)
	}
}

@(test)
rand_stays_within_fifteen_bits :: proc(t: ^testing.T) {
	r := sim.rand_init(0xDEADBEEF)
	for _ in 0 ..< 10_000 {
		v := sim.rand_next(&r)
		testing.expect(t, v >= 0 && v <= sim.RAND_MAX, "rand out of range")
	}
}

@(test)
random_int_matches_u_utils_random_int :: proc(t: ^testing.T) {
	r := sim.rand_init(42)
	want := [6]i32{17, 15, 11, 17, 17, 14}
	for w in want {
		testing.expect_value(t, sim.random_int(&r, 10, 20, 0), w)
	}
}

@(test)
random_int_equal_bounds_consume_nothing :: proc(t: ^testing.T) {
	// The early-out changes how many numbers are drawn, so it must hold.
	a := sim.rand_init(7)
	b := sim.rand_init(7)
	testing.expect_value(t, sim.random_int(&a, 5, 5, 0), i32(5))
	testing.expect_value(t, a.next, b.next)
}

@(test)
random_float_matches_u_utils_random_float :: proc(t: ^testing.T) {
	r := sim.rand_init(42)
	want := [4]f32{1.082323670387268, 1.0198217630386353, 0.9659870862960815, 1.2770317792892456}
	for w in want {
		testing.expect_value(t, sim.random_float(&r, 0.5, 1.5, 0), w)
	}
}

@(test)
random_float_reproduces_the_reversed_bounds_quirk :: proc(t: ^testing.T) {
	// With a > b the original still offsets by min(a, b), landing in
	// [2b - a, b]. Reproduced deliberately.
	r := sim.rand_init(3)
	for _ in 0 ..< 1000 {
		v := sim.random_float(&r, 10, 4, 0)
		testing.expect(t, v >= -2 && v <= 4, "reversed bounds land in [2b-a, b]")
	}
}
