package sim

// The original's random number generator, reproduced exactly.
//
// Deimos Rising uses the Metrowerks Standard Library rand()/srand() -- the
// classic ANSI C linear congruential generator -- recovered from `_rand` and
// `_srand` in the decompilation corpus:
//
//     next = next * 1103515245 + 12345
//     return (next >> 16) & 0x7fff
//
// Seeded once per session by G_Game_Play via `srand(seed)`, where the seed is
// the value a film records at offset +0x04. Film replay is only faithful if
// every draw happens in the original order, so the generator lives in the
// simulation state and nowhere else. core:math/rand is banned from sim/ for
// the same reason.
//
// Important: the original draws from this ONE generator for gameplay, for
// particles (G_Particle_NewGroup) AND for sound variation (U_Sound_Play picks
// pitch and volume with it). Those draws are part of the gameplay sequence.
// See docs/phase-4-sim.md.

RAND_MAX :: 32767

Rand :: struct {
	next: u32,
	// Optional record of every RandomInt/RandomFloat call, for diffing against
	// the original's gdb trace (see oracle/). nil in normal play and netplay.
	// A rollback snapshot copies the pointer, which is harmless: tracing is a
	// single-timeline debugging aid.
	log:  ^Draw_Log,
}

// Where a draw was made, named by the return address of the corresponding
// call in the original (e.g. 0x40f80d-style addresses inside G_Entity::
// ChangeState). Every call site ported from the original passes its address,
// so the first divergence from the reference trace names the function to
// read. Zero means "not a ported site" and never matches the trace.
Site :: distinct u32

Draw_Kind :: enum u8 {
	Int,   // U_Utils_RandomInt; a, b are the i32 bounds
	Float, // U_Utils_RandomFloat; a, b are the f32 bounds, as bits
}

// One U_Utils_RandomInt/RandomFloat call. Recorded even when the bounds are
// equal and nothing is drawn, because the original trace records the call too
// and the bounds themselves are a strong check on ported data and arithmetic.
Draw :: struct {
	site:  Site,
	kind:  Draw_Kind,
	a, b:  u32,
	frame: u32,
}

// Caller-owned, fixed-capacity log: sim/ stays allocation-free.
Draw_Log :: struct {
	draws:   []Draw,
	count:   int,
	dropped: int,
	frame:   u32, // set by step(); 0 while a session is being set up
}

draw_log_entries :: proc "contextless" (l: ^Draw_Log) -> []Draw {
	return l.draws[:l.count]
}

@(private)
record :: proc "contextless" (r: ^Rand, site: Site, kind: Draw_Kind, a, b: u32) {
	l := r.log
	if l == nil {
		return
	}
	if l.count == len(l.draws) {
		l.dropped += 1
		return
	}
	l.draws[l.count] = Draw{site = site, kind = kind, a = a, b = b, frame = l.frame}
	l.count += 1
}

// srand
rand_init :: proc "contextless" (seed: u32, log: ^Draw_Log = nil) -> Rand {
	return Rand{next = seed, log = log}
}

// rand: 15 bits, 0 ..= 32767.
rand_next :: proc "contextless" (r: ^Rand) -> i32 {
	r.next = r.next * 1103515245 + 12345
	return i32((r.next >> 16) & 0x7fff)
}

// U_Utils_RandomInt(lo, hi): inclusive, `lo + rand() % (hi - lo + 1)`.
//
// Uses C's truncating remainder, which Odin's `%` on signed integers matches.
// Equal bounds return without drawing, exactly as the original does -- that
// early-out changes how many numbers are consumed, so it matters.
random_int :: proc "contextless" (r: ^Rand, lo, hi: i32, site: Site) -> i32 {
	record(r, site, .Int, u32(lo), u32(hi))
	if lo == hi {
		return lo
	}
	span := hi - lo + 1
	if span == 0 {
		// The original divides by zero here. Never observed in the corpus;
		// draw anyway so the sequence advances as it would have.
		_ = rand_next(r)
		return lo
	}
	return lo + rand_next(r) % span
}

// U_Utils_RandomFloat(a, b): `(b - a) * rand() / 32767.0 + min(a, b)`.
//
// Reproduced including its quirk: when a > b the span is negative but the
// offset is still min(a, b), so the result lands in [2b - a, b] rather than
// [b, a]. Equal bounds return `a` without drawing.
//
// FIDELITY NOTE: computed in f32, one rounding per operation. The original is
// x87 code and may carry wider intermediates; whether that ever changes a
// result is to be established against the reference oracle.
random_float :: proc "contextless" (r: ^Rand, a, b: f32, site: Site) -> f32 {
	record(r, site, .Float, transmute(u32)a, transmute(u32)b)
	if a == b {
		return a
	}
	lo := min(a, b)
	v := f32(rand_next(r))
	return (b - a) * v / f32(RAND_MAX) + lo
}
