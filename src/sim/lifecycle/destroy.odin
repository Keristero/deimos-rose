package lifecycle

// Destruction and what it leaves behind: G_Entity::Destroy, spawning on water
// (G_Entity::CanSpawnOnMedia) and random bonuses.

import "dr:sim"
import "dr:sim/systems/debris_system"
import "dr:sim/systems/notice_system"

// G_Bgnd_MediaMask_GetSurfaceAtLoc: 1 for water, 0 otherwise. `x`, `y` are
// map pixels.
media_surface :: proc "contextless" (s: ^sim.State, x, y: i32) -> i32 {
	l := sim.level_def(s)
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
can_spawn_on_media :: proc(s: ^sim.State, e: sim.Entity) -> bool {
	u := sim.unit_of(s, e)
	if !u.is_ground_based || u.do_death_spawn_on_any_media {
		return true
	}
	x := sim.trunc_i32(e.loc.x) + 32
	y := sim.single(s, sim.Bgnd).view_top + sim.trunc_i32(e.loc.y)
	if media_surface(s, x, y) != 1 {
		return true
	}
	splash := sim.NONE
	switch u.media_impact_size {
	case sim.res_id("med "):
		splash = s.defs.perm_objects[8]
	case sim.res_id("lara"):
		splash = s.defs.perm_objects[sim.roll_int(s, 0, 1, 0x415ba7) == 0 ? 9 : 8]
	case sim.res_id("mera"):
		switch sim.roll_int(s, 0, 2, 0x415b4e) {
		case 0:
			splash = s.defs.perm_objects[6]
		case 1:
			splash = s.defs.perm_objects[7]
		case:
			splash = s.defs.perm_objects[8]
		}
	case sim.res_id("smra"):
		splash = s.defs.perm_objects[sim.roll_int(s, 0, 1, 0x415afe) == 0 ? 7 : 6]
	case sim.res_id("larg"):
		splash = s.defs.perm_objects[9]
	case sim.res_id("smal"):
		splash = s.defs.perm_objects[7]
	case sim.res_id("tiny"):
		splash = s.defs.perm_objects[6]
	}
	if splash != sim.NONE {
		spawn_from(s, e, splash)
	}
	return false
}

// A spawn left behind by an entity: at its location, owned by it.
spawn_from :: proc(s: ^sim.State, e: sim.Entity, unit: sim.Res_ID) {
	req := sim.spawn_request(unit)
	req.loc = e.loc
	req.owner_player = e.owner_player
	req.owner = {e.pool_index, e.number}
	eg_request_spawn(s, req)
}

// G_Entity::Destroy. `player` is who destroyed it, or -1.
entity_destroy :: proc(s: ^sim.State, e: sim.Entity, player: i32, time: i32) {
	if e.deleted {
		return
	}
	u := sim.unit_of(s, e)
	sim.record_event(s, sim.Event{kind = .Destroy, unit = u.id, number = e.number, loc = e.loc})
	glow_stop(e.obj)
	if !e.is_air && u.destruct_create_obstacle {
		debris_system.debris_new(s, object_bounds(e.obj))
	}
	if u.destruct_particle != sim.NONE {
		sim.particle_burst(s, e.loc, u.destruct_particle_color, u.destruct_particle, u.is_ground_based)
	}
	if u.destruct_spawn != sim.NONE && can_spawn_on_media(s, e) {
		spawn_from(s, e, u.destruct_spawn)
	}
	if u.destruct_notice != "" && u.destruct_notice != "none" {
		notice_system.notice_request_destruct(s, u.destruct_notice)
	}
	if u.destruct_sound != sim.NONE {
		sim.sound_play(s, sim.Sound_Settings {
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
		sim.single(s, sim.Accuracy).destroyed += 1
	}
	if u.destruct_release_random_bonus {
		release_random_bonus(s, e)
	}
}

// The random bonus at the end of G_Entity::Destroy: one RandomInt(0, 100)
// against the cumulative percentages in perm floats 0xd1..0xd9, picking one
// of perm objects 0x19..0x22 (RandomBonus_1..10).
@(private = "file")
release_random_bonus :: proc(s: ^sim.State, e: sim.Entity) {
	pf := s.defs.perm_floats
	pct :: proc "contextless" (pf: [sim.PERM_FLOATS]f32, i: int) -> i32 {
		return sim.trunc_i32(pf[i])
	}
	r := sim.roll_int(s, 0, 100, 0x415427)
	bonus := sim.NONE
	idx := -1
	switch {
	case r < pct(pf, 0xd1):
		if sim.single(s, sim.Accuracy).reward_this_level {
			if r < pct(pf, 0xda) {
				bonus = s.defs.perm_objects[0x1e]
				sim.single(s, sim.Accuracy).reward_this_level = false
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
	case sim.single(s, sim.Level_Info).number < pct(pf, 0xdb):
		idx = 0x20
	case r < pct(pf, 0xd9):
		idx = 0x21
	case:
		idx = 0x22
	}
	if idx >= 0 {
		bonus = s.defs.perm_objects[idx]
	}
	if bonus != sim.NONE {
		spawn_from(s, e, bonus)
	}
}
