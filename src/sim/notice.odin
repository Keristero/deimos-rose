package sim

// G_Notice: on-screen notices ("Mariner Valley", "Tracked Entity Spawned").
// Mostly presentation, but G_Notice_Process plays a notice's sound when it
// appears, which draws from the RNG. Until notices are ported, a request with
// a sound marks itself unported.

// FUN_0041cdf0 -> G_Notice_Request.
notice_request :: proc "contextless" (s: ^State, u: ^Unit, time: i32) {
	if u.entry_notice == "none" {
		return
	}
	if u.entry_notice_sound != NONE {
		unported(s, 0x41cdf0)
	}
}

// G_Notice_Process.
notice_process :: proc "contextless" (s: ^State) {}
