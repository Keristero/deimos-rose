package oracle

import "dr:sim"

// Where the simulation first disagrees with the original.
Divergence :: struct {
	index: int, // position in the call sequence
	want:  Maybe(sim.Draw), // nil: the simulation made extra calls
	got:   Maybe(sim.Draw), // nil: the simulation stopped short
}

Diff :: struct {
	matched: int, // calls identical to the original, from the start
	want:    int,
	got:     int,
	first:   Maybe(Divergence),
}

// Compares call sequences exactly: site, kind, bounds (floats bit for bit) and
// the step the call happened in. Matching is a prefix: everything after the
// first difference is untrustworthy, because the RNG has desynchronised.
diff :: proc "contextless" (want, got: []sim.Draw) -> (d: Diff) {
	d.want, d.got = len(want), len(got)
	n := min(len(want), len(got))
	for i in 0 ..< n {
		if want[i] != got[i] {
			d.matched = i
			d.first = Divergence{index = i, want = want[i], got = got[i]}
			return
		}
	}
	d.matched = n
	if len(want) > n {
		d.first = Divergence{index = n, want = want[n]}
	} else if len(got) > n {
		d.first = Divergence{index = n, got = got[n]}
	}
	return
}
