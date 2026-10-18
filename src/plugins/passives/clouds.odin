package passives

// Corrosive clouds (Hit_Cloud): new content, from the Weapon 2 charge of
// notes/extra-weapons-and-passives-3.md, "hits from projectiles create
// corrosive clouds which linger for (2 seconds base)", which "deal small
// amounts of damage to enemies inside them". A shot whose scope has the
// stat leaves one where it hits (the core's Shot_Hit), and each step every
// air target inside a cloud takes CLOUD_DAMAGE (cloud_system). That damage
// is not a hit (collision_system.entity_damage): it neither waits for a
// target's hit delay nor starts it, so the shots that land on a target in
// a cloud are not turned away. The clouds are the session's (Clouds), so a
// rollback restores them; the view draws them from there.

import "dr:sim"
import "dr:sim/lifecycle"
import "dr:sim/stats"
import "dr:sim/systems/collision_system"

// The clouds one session keeps: as many as a charge's release leaves at
// once, and more. A new one past them replaces the oldest.
MAX_CLOUDS :: 32

// The notes' base, before Cloud_Lifetime.
CLOUD_SECONDS :: 2
// Provisional, picked by eye: a cloud is the size of a small enemy, and a
// hit within it of another of its player's clouds keeps that one
// lingering rather than forming a second over it.
CLOUD_RADIUS :: 20
// Provisional, tuned by the DPS report: shields a step, to a target
// inside any cloud, once a step however many it is in.
CLOUD_DAMAGE :: 0.01

Cloud :: struct {
	loc:    sim.Vec,
	start:  i32, // the step it formed
	until:  i32, // the step it is gone by
	level:  i32, // Level_Info.played: a cloud does not outlast its level
	player: i8,
}

Clouds :: struct {
	clouds: [MAX_CLOUDS]Cloud,
	next:   i32,
}

clouds_of :: #force_inline proc "contextless" (s: ^sim.State) -> ^Clouds {
	return sim.single(s, Clouds)
}

// Whether `c` is still there at `time`, on level `level`.
cloud_live :: #force_inline proc "contextless" (c: ^Cloud, time, level: i32) -> bool {
	return c.until > time && c.level == level
}

// Shot_Hit: a hit, dealt or turned away, leaves a cloud where the shot
// landed, if its scope has Hit_Cloud.
cloud_hit :: proc(s: ^sim.State, shot, target: sim.Entity, dealt: f32, time: i32) {
	if shot.owner_player < 0 || !stats.shaped_stat(s, shot, .Hit_Cloud).enabled {
		return
	}
	life := stats.scale_i32(CLOUD_SECONDS * stats.step_hz(s), stats.shaped_stat(s, shot, .Cloud_Lifetime).percent)
	cs := clouds_of(s)
	level := sim.single(s, sim.Level_Info).played
	for &c in cs.clouds {
		if cloud_live(&c, time, level) && i32(c.player) == shot.owner_player && collision_system.circles_collide(c.loc, CLOUD_RADIUS, shot.loc, 0) {
			c.until = max(c.until, time + life)
			return
		}
	}
	cs.clouds[cs.next] = {loc = shot.loc, start = time, until = time + life, level = level, player = i8(shot.owner_player)}
	cs.next = (cs.next + 1) % MAX_CLOUDS
}

// Each step, after the entities have moved and hit: every air target a
// player's air shot could hit takes CLOUD_DAMAGE inside a cloud, for the
// player of the first it is in.
cloud_system :: proc(s: ^sim.State, step: ^sim.Step) {
	cs := clouds_of(s)
	time := sim.single(s, sim.Clock).time
	level := sim.single(s, sim.Level_Info).played
	live: [MAX_CLOUDS]^Cloud
	n := 0
	for &c in cs.clouds {
		if cloud_live(&c, time, level) {
			live[n] = &c
			n += 1
		}
	}
	if n == 0 {
		return
	}
	walk := sim.walk_entities(s)
	for e in sim.walk_next(&walk) {
		if !collision_system.air_shot_can_hit(s, e) || e.shields <= 0 {
			continue
		}
		b := lifecycle.object_bounds(e.obj)
		r := f32(lifecycle.halve(b.bottom - b.top))
		for c in live[:n] {
			if collision_system.circles_collide(c.loc, CLOUD_RADIUS, e.loc, r) {
				collision_system.entity_damage(s, e, CLOUD_DAMAGE, i32(c.player), time)
				break
			}
		}
	}
}
