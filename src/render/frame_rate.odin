package render

import "dr:sim"

// What a plugin asks of the frame rate. The original presents one frame a
// step, 30 a second; while a plugin registered here is on, the game
// presents at the rate it gives instead, drawing between steps (D33). The
// simulation steps at 30 Hz either way (D17). The first registered that is
// on wins.

MAX_FRAME_RATES :: 4

Frame_Rate :: struct {
	plugin: sim.Plugin_ID,
	fps:    proc() -> i32, // asked once, when the plugin comes on
}

// Called from registration steps only (sim.register_step), like render_system_register.
frame_rate_register :: proc(f: Frame_Rate) {
	sim.registry_add(&shared.frame_rates, f)
}

registered_frame_rates :: proc "contextless" () -> []Frame_Rate {
	return sim.registry_items(&shared.frame_rates)
}
