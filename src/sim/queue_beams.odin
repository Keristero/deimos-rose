package sim

// The Discharge Beam's shots this step (weapon_system/beam.odin), for
// presentation to draw as a line that fades.

Beam_Event :: struct {
	from:    Vec, // the gun
	to_y:    f32, // where it stopped; above the screen if nothing stopped it
	width:   f32,
	charged: bool,
	player:  i32,
}

MAX_BEAM_EVENTS :: 8

Beam_Queue :: struct {
	events: [MAX_BEAM_EVENTS]Beam_Event,
	count:  int,
}

// The most targets one beam can pass through. A full screen of the densest
// formation (Shuriken, groups of 11) in one column is well under this.
MAX_BEAM_TARGETS :: 64

// How far above the top of the screen an unstopped beam is drawn to.
BEAM_OVERSHOOT :: 16
