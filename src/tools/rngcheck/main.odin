// Prints a single FNV-1a digest of a long, fixed-seed sequence of
// sim.random_int/random_float draws, interleaved the way real call sites
// mix them (see sim/rand.odin: both draw from the one shared LCG). Two
// builds of this program compiled with different codegen settings --
// different -microarch, -target-features, or -o -- producing the same
// digest is evidence that sim/'s RNG is safe against exactly the kind of
// platform/compiler divergence that would desync a rollback netplay session
// between a Linux and a Windows build (see mise.toml's rng:determinism task
// and docs/decisions.md D27): random_int is pure integer wraparound
// arithmetic, portable by the Odin spec, but random_float's f32 arithmetic
// could in principle round differently under different instruction
// selection (e.g. a fused multiply-add). This program is the harness that
// actually exercises that risk instead of just asserting it away.
package rngcheck

import "core:fmt"

import "dr:sim"

@(private = "file")
mix :: proc(h: ^u64, v: u64) {
	x := v
	for _ in 0 ..< 8 {
		h^ ~= x & 0xff
		h^ *= 0x100000001b3
		x >>= 8
	}
}

main :: proc() {
	r := sim.rand_init(0x5EED)
	h: u64 = 0xcbf29ce484222325
	for i in 0 ..< 20_000 {
		lo := i32(i%2000) - 1000
		hi := lo + i32(i%37) + 1
		iv := sim.random_int(&r, lo, hi, 0)
		mix(&h, u64(u32(iv)))

		fa := f32(i%401) - 200.0
		fb := fa + f32(i%53) + 1.0
		fv := sim.random_float(&r, fa, fb, 0)
		mix(&h, u64(transmute(u32)fv))
	}
	fmt.printfln("%016x", h)
}
