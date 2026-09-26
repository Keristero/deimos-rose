package sim

// Marks left on the terrain itself.
//
// The original draws some sprites into the scrolling map buffer rather than
// the frame, so they stay where they were put and scroll with the ground:
// craters and tank tracks while they live (a state's stateDrawToTerrain), and
// the wreck of anything with destructDrawToTerrain the moment it is swept up
// (FUN_0041b2d0). Thirty-two units leave a wreck this way -- the fortress that
// dominates the middle of Lucena is one of them.
//
// The simulation does not own the map image, so it records what to stamp and
// where; the presentation applies it. Order matters, so this is a queue like
// the sound and particle ones, cleared at the top of every step.

Stamp :: struct {
	sprite:       Res_ID,
	frame:        i32,
	loc:          Vec, // screen space, as the object had it
	scale:        f32,
	visibility:   f32,
	is_air:       bool,
	casts_shadow: bool,
	draw_layer:   Res_ID,
	// The scroll position when the stamp was made, so the presentation can
	// place it in map space.
	view_top:     i32,
}

MAX_STAMPS :: 32

Stamp_Queue :: struct {
	events: [MAX_STAMPS]Stamp,
	count:  int,
}

stamp_object :: proc "contextless" (s: ^State, o: ^Game_Object, casts_shadow: bool) {
	if o.sprite == NONE || s.stamps.count >= MAX_STAMPS {
		return
	}
	s.stamps.events[s.stamps.count] = Stamp {
		sprite       = o.sprite,
		frame        = o.frame,
		loc          = o.loc,
		scale        = o.scale,
		visibility   = o.visibility,
		is_air       = o.is_air,
		casts_shadow = casts_shadow,
		draw_layer   = o.draw_layer,
		view_top     = single(s, Bgnd).view_top,
	}
	s.stamps.count += 1
}
