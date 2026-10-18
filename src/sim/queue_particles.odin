package sim

// Particle bursts are presentation, but G_Particle_NewGroup draws a colour
// for every particle from the gameplay RNG, so the burst is created here and
// handed to the renderer as an event, with each particle's draw (which of
// the colour's five shades it takes). The count is fixed by the size id;
// the "ice" variants differ only in how they move.

// Particle bursts are presentation, but G_Particle_NewGroup draws a colour
// for every particle from the gameplay RNG, so the burst is created here and
// handed to the renderer as an event, with each particle's draw (which of
// the colour's five shades it takes). The count is fixed by the size id;
// the "ice" variants differ only in how they move.
Particle_Event :: struct {
	loc:    Vec,
	color:  Color,
	size:   Res_ID,
	ground: bool,
	shades: [MAX_PARTICLES_PER_GROUP]u8,
}

MAX_PARTICLES_PER_GROUP :: 40 // the group's 0x28 slots

MAX_PARTICLE_EVENTS :: 64

Particle_Queue :: struct {
	events: [MAX_PARTICLE_EVENTS]Particle_Event,
	count:  int,
}

// The number of particles a burst of this size id spawns; presentation reuses
// it so its own particle count matches what the RNG draws in particle_burst
// were actually for.
particle_count :: proc "contextless" (size: Res_ID) -> i32 {
	switch size {
	case res_id("med "), res_id("meci"):
		return 20
	case res_id("larg"), res_id("laci"):
		return 40
	case res_id("smal"), res_id("smci"):
		return 10
	case res_id("tiny"), res_id("tici"):
		return 5
	}
	return 0
}

// G_Particle_NewGroup.
particle_burst :: proc "contextless" (s: ^State, loc: Vec, color: Color, size: Res_ID, ground: bool) {
	n := particle_count(size)
	if size == NONE || n == 0 {
		return
	}
	ev := Particle_Event{loc = loc, color = color, size = size, ground = ground}
	for i in 0 ..< n {
		ev.shades[i] = u8(roll_int(s, 0, 4, 0x42ee00))
	}
	record_event(s, Event{kind = .Burst, unit = size, loc = loc})
	q := &s.particles
	if q.count < MAX_PARTICLE_EVENTS {
		q.events[q.count] = ev
		q.count += 1
	}
}
