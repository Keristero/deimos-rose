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

// Rollback netplay requires two machines -- potentially a Linux build and a
// Windows build (mise.toml's build:linux/build:windows), different
// compilers, different CPUs -- to compute bit-identical sim.State from the
// same inputs. random_int's LCG is pure u32/i32 wraparound arithmetic,
// portable by the Odin language spec on any target. random_float
// additionally does f32 arithmetic, which is the one place a different
// target/microarch's instruction selection (e.g. fusing a multiply and add
// into one fused-multiply-add, which rounds once instead of twice) could in
// principle produce different bits for the same input -- exactly the risk
// random_float's own "FIDELITY NOTE" comment (sim/rand.odin) flags.
//
// This folds a long, mixed sequence of random_int/random_float draws (the
// same shared-generator mixing real call sites do) from a fixed seed into
// one FNV-1a digest and checks it against a frozen value. It is a
// regression baseline, not by itself proof of cross-platform safety -- that
// requires actually running this same suite on a second platform. What *is*
// independently verified in this sandbox (no working Windows cross-link or
// second OS available, see docs/decisions.md D27): tools/rngcheck built
// under -o:none, -o:speed, -microarch:native and an explicit
// -target-features:"fma,avx2" all print this exact digest
// (tools/rngcheck/determinism_check.sh, `mise run rng:determinism`) --
// the digest below was taken from that tool's own output, not invented.
@(test)
rand_sequence_digest_is_codegen_stable :: proc(t: ^testing.T) {
	r := sim.rand_init(0x5EED)
	h: u64 = 0xcbf29ce484222325
	mix :: proc(h: ^u64, v: u64) {
		x := v
		for _ in 0 ..< 8 {
			h^ ~= x & 0xff
			h^ *= 0x100000001b3
			x >>= 8
		}
	}
	for i in 0 ..< 20_000 {
		lo := i32(i % 2000) - 1000
		hi := lo + i32(i % 37) + 1
		iv := sim.random_int(&r, lo, hi, 0)
		mix(&h, u64(u32(iv)))

		fa := f32(i % 401) - 200.0
		fb := fa + f32(i % 53) + 1.0
		fv := sim.random_float(&r, fa, fb, 0)
		mix(&h, u64(transmute(u32)fv))
	}
	testing.expect_value(t, h, u64(0x0071e4eb5e5f0743))
}
