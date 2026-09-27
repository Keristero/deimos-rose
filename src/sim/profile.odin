package sim

import "base:intrinsics"

// Where a step's time goes, system by system and stage by stage, for
// tools/simbench (`mise run bench:profile`). Off unless built with
// -define:DR_SIM_PROFILE=true; then run_systems and the stage runners
// count the processor's cycles around each call.
//
// A cycle counter is wall-clock data, which sim/ otherwise keeps out, so
// it is held apart: the counts go only into `profile`, which is not part of
// the state, and nothing in the simulation reads them. With the define
// off, profile_clock is a constant 0 and the counting compiles away.

SIM_PROFILE :: #config(DR_SIM_PROFILE, false)

Profile_Count :: struct {
	cycles: i64,
	calls:  i64,
}

Profile :: struct {
	systems:       [MAX_SYSTEMS]Profile_Count, // by registry index
	player_stages: [MAX_STAGES]Profile_Count,
	stages:        [MAX_STAGES]Profile_Count,
}

profile: Profile

profile_clock :: #force_inline proc "contextless" () -> i64 {
	when SIM_PROFILE {
		return intrinsics.read_cycle_counter()
	} else {
		return 0
	}
}

@(private)
profile_add :: #force_inline proc "contextless" (c: ^Profile_Count, since: i64) {
	when SIM_PROFILE {
		c.cycles += intrinsics.read_cycle_counter() - since
		c.calls += 1
	}
}

profile_reset :: proc "contextless" () {
	profile = {}
}
