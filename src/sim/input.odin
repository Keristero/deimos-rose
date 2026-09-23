package sim

// Player controls, as described by the original Read Me and driven by
// G_Input_CachePlayerInputs / G_Film::GetInputs in the 2003 build.
//
// The simulation is advanced purely by these values plus a seed. Nothing else
// may influence it -- that is what makes films replayable and rollback
// possible.
Button :: enum u8 {
	Up,
	Down,
	Left,
	Right,
	Fire_Air,     // held to charge, released to fire
	Fire_Ground,  // plasma bombs against ground targets
	Change_Air,   // cycle available air-to-air weapons
	// Not an original control: toggles a netplay pause (session_step). An
	// input bit rather than a network message, so it reaches the peer and
	// is replayed on rollback exactly like every other button, and both
	// sides pause on the same frame. No film can set it -- data/film.odin
	// maps the original's seven bits through an explicit table.
	Pause,
}

Buttons :: bit_set[Button; u16]

MAX_PLAYERS :: 2

// One frame of input for the whole session.
Frame_Input :: [MAX_PLAYERS]Buttons

pressed :: proc "contextless" (now, before: Buttons, b: Button) -> bool {
	return b in now && b not_in before
}

released :: proc "contextless" (now, before: Buttons, b: Button) -> bool {
	return b not_in now && b in before
}
