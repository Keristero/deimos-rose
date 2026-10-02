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

main :: proc() {
	// Every registry filled, in the same order on every platform.
	sim.register_all()
	fmt.printfln("%016x", sim.rand_digest(0x5EED, 20_000))
}
