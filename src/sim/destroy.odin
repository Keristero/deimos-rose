package sim

// Destruction and what it leaves behind: G_Entity::Destroy, spawning on water
// (G_Entity::CanSpawnOnMedia), particle bursts and random bonuses.

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
		ev.shades[i] = u8(random_int(&s.rng, 0, 4, 0x42ee00))
	}
	record_event(s, Event{kind = .Burst, unit = size, loc = loc})
	q := &s.particles
	if q.count < MAX_PARTICLE_EVENTS {
		q.events[q.count] = ev
		q.count += 1
	}
}

// G_Bgnd_MediaMask_GetSurfaceAtLoc: 1 for water, 0 otherwise. `x`, `y` are
// map pixels.
media_surface :: proc "contextless" (s: ^State, x, y: i32) -> i32 {
	l := s.level
	if l.media_scale < 1 {
		return 0
	}
	mx, my := x / l.media_scale, y / l.media_scale
	if mx < 0 || mx >= l.media_w || my < 0 || my >= l.media_h {
		return 0
	}
	return l.media[my * l.media_w + mx] == 0x1f ? 1 : 0
}

// G_Entity::CanSpawnOnMedia: a ground unit dying over water splashes instead
// of leaving its usual remains. Returns whether the usual spawn may happen.
//
// Call sites are not in source order: the trace shows an "smra" unit (the
// only kind that ships, with "smal") drawing at 0x415afe, the first
// RandomInt in the function, so the compiler emitted that branch first.
can_spawn_on_media :: proc(s: ^State, e: ^Entity) -> bool {
	u := unit_of(s, e)
	if !u.is_ground_based || u.do_death_spawn_on_any_media {
		return true
	}
	x := trunc_i32(e.loc.x) + 32
	y := s.bgnd.view_top + trunc_i32(e.loc.y)
	if media_surface(s, x, y) != 1 {
		return true
	}
	splash := NONE
	switch u.media_impact_size {
	case res_id("med "):
		splash = s.defs.perm_objects[8]
	case res_id("lara"):
		splash = s.defs.perm_objects[random_int(&s.rng, 0, 1, 0x415ba7) == 0 ? 9 : 8]
	case res_id("mera"):
		switch random_int(&s.rng, 0, 2, 0x415b4e) {
		case 0:
			splash = s.defs.perm_objects[6]
		case 1:
			splash = s.defs.perm_objects[7]
		case:
			splash = s.defs.perm_objects[8]
		}
	case res_id("smra"):
		splash = s.defs.perm_objects[random_int(&s.rng, 0, 1, 0x415afe) == 0 ? 7 : 6]
	case res_id("larg"):
		splash = s.defs.perm_objects[9]
	case res_id("smal"):
		splash = s.defs.perm_objects[7]
	case res_id("tiny"):
		splash = s.defs.perm_objects[6]
	}
	if splash != NONE {
		spawn_from(s, e, splash)
	}
	return false
}

// A spawn left behind by an entity: at its location, owned by it.
spawn_from :: proc(s: ^State, e: ^Entity, unit: Res_ID) {
	req := spawn_request(unit)
	req.loc = e.loc
	req.owner_player = e.owner_player
	req.owner = {e.pool_index, e.number}
	eg_request_spawn(s, req)
}

// G_Entity::Destroy. `player` is who destroyed it, or -1.
entity_destroy :: proc(s: ^State, e: ^Entity, player: i32, time: i32) {
	if e.deleted {
		return
	}
	u := unit_of(s, e)
	record_event(s, Event{kind = .Destroy, unit = u.id, number = e.number, loc = e.loc})
	glow_stop(&e.obj)
	if !e.is_air && u.destruct_create_obstacle {
		debris_new(s, object_bounds(&e.obj))
	}
	if u.destruct_particle != NONE {
		particle_burst(s, e.loc, u.destruct_particle_color, u.destruct_particle, u.is_ground_based)
	}
	if u.destruct_spawn != NONE && can_spawn_on_media(s, e) {
		spawn_from(s, e, u.destruct_spawn)
	}
	if u.destruct_notice != "" && u.destruct_notice != "none" {
		notice_request_destruct(s, u.destruct_notice)
	}
	if u.destruct_sound != NONE {
		sound_play(s, Sound_Settings {
			id         = u.destruct_sound,
			min_volume = u.destruct_sound_min_volume,
			max_volume = u.destruct_sound_max_volume,
			priority   = u.destruct_sound_priority,
			min_pitch  = u.destruct_sound_min_pitch,
			max_pitch  = u.destruct_sound_max_pitch,
		}, true)
	}
	e.deleted = true
	e.target_player = player
	e.destroyed = true
	if u.include_in_ground_accuracy_count {
		s.accuracy_destroyed += 1
	}
	if u.destruct_release_random_bonus {
		release_random_bonus(s, e)
	}
}

// The random bonus at the end of G_Entity::Destroy: one RandomInt(0, 100)
// against the cumulative percentages in perm floats 0xd1..0xd9, picking one
// of perm objects 0x19..0x22 (RandomBonus_1..10).
@(private = "file")
release_random_bonus :: proc(s: ^State, e: ^Entity) {
	pf := s.defs.perm_floats
	pct :: proc "contextless" (pf: [PERM_FLOATS]f32, i: int) -> i32 {
		return trunc_i32(pf[i])
	}
	r := random_int(&s.rng, 0, 100, 0x415427)
	bonus := NONE
	idx := -1
	switch {
	case r < pct(pf, 0xd1):
		if s.accuracy_reward_this_level {
			if r < pct(pf, 0xda) {
				bonus = s.defs.perm_objects[0x1e]
				s.accuracy_reward_this_level = false
			} else {
				bonus = s.defs.perm_objects[0x19]
			}
		} else {
			idx = 0x19
		}
	case r < pct(pf, 0xd2):
		idx = 0x1a
	case r < pct(pf, 0xd3):
		idx = 0x1b
	case r < pct(pf, 0xd4):
		idx = 0x1c
	case r < pct(pf, 0xd5):
		idx = 0x1d
	case r < pct(pf, 0xd6):
		idx = 0x1e
	case r < pct(pf, 0xd7):
		idx = 0x1f
	case r < pct(pf, 0xd8):
		bonus = s.defs.perm_objects[0x20]
	case s.level_number < pct(pf, 0xdb):
		idx = 0x20
	case r < pct(pf, 0xd9):
		idx = 0x21
	case:
		idx = 0x22
	}
	if idx >= 0 {
		bonus = s.defs.perm_objects[idx]
	}
	if bonus != NONE {
		spawn_from(s, e, bonus)
	}
}
