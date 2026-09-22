package sim

// Deterministic RNG owned by the simulation state.
//
// core:math/rand is deliberately unavailable here: a global, implicitly seeded
// generator would silently desync rollback and make film replay
// irreproducible. G_Film::GetRandomSeed shows the original stored its seed in
// the replay for exactly this reason.
Rand :: struct {
	state: u32,
}

rand_init :: proc "contextless" (seed: u32) -> Rand {
	// Avoid the xorshift fixed point at zero.
	return Rand{state = seed == 0 ? 0x9E3779B9 : seed}
}

rand_u32 :: proc "contextless" (r: ^Rand) -> u32 {
	x := r.state
	x ~= x << 13
	x ~= x >> 17
	x ~= x << 5
	r.state = x
	return x
}

// Uniform in [0, n). n == 0 yields 0.
rand_below :: proc "contextless" (r: ^Rand, n: u32) -> u32 {
	if n == 0 {
		return 0
	}
	return rand_u32(r) % n
}
