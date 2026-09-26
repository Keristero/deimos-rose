package weapon_system

// The Chaingun's charge (a weapon with `aimed_release`, docs/new-weapons.md):
// new content, not the original's. Where an original weapon's release
// spawns its release unit at the ship, each release volley here is two
// parallel shots aimed at the nearest enemy in the air, leading it by its
// current velocity. With nothing to aim at they fly straight ahead.

import "core:math"

import "dr:sim"
import "dr:sim/lifecycle"
import "dr:sim/systems/collision_system"

// How far either side of the line of fire the two shots of a volley fly.
// Provisional: picked by eye against the rice sprite's width.
AIMED_PAIR_OFFSET :: 3

aimed_release_spawn :: proc(s: ^sim.State, h: ^sim.Weapon_Handler, wd: ^sim.Weapon, at: sim.Vec) {
	u := sim.unit_find(s.defs, wd.powerup_air_release_spawn)
	if u == nil {
		return
	}
	heading: i32 = 0
	if t, ok := aimed_target(s, at); ok {
		aim := aimed_intercept(t.loc - at, t.vel, (u.initial_speed_min + u.initial_speed_max) / 2)
		if aim != {} {
			heading = sim.invert_angle(sim.angle_from_vector(aim))
		}
	}
	d := sim.vector_from_angle(sim.invert_angle(heading))
	across := sim.Vec{-d.y, d.x} * AIMED_PAIR_OFFSET
	for side in ([2]f32{-1, 1}) {
		req := sim.spawn_request(wd.powerup_air_release_spawn)
		req.owner_player = h.player
		req.loc = at + across * side
		req.explicit_heading = true
		req.heading = heading
		lifecycle.eg_request_spawn(s, req)
	}
}

// The nearest entity to `at` that a player's air shot can hit, on screen.
aimed_target :: proc "contextless" (s: ^sim.State, at: sim.Vec) -> (target: sim.Entity, ok: bool) {
	w := sim.single(s, sim.Pool)
	width := s.defs.perm_floats[sim.PF_VISIBLE_GAME_WIDTH]
	height := s.defs.perm_floats[sim.PF_VISIBLE_GAME_HEIGHT]
	best: f32
	g := w.active.head
	for g != sim.NO_LINK {
		i := sim.group_at(s, g).entities.head
		for i != sim.NO_LINK {
			e := sim.entity_at(s, i)
			i = sim.link_of(sim.entity_links(s), i).next
			if !air_shot_can_hit(s, e) {
				continue
			}
			if e.loc.x < 0 || e.loc.x > width || e.loc.y < 0 || e.loc.y > height {
				continue
			}
			d := e.loc - at
			if dist := d.x * d.x + d.y * d.y; !ok || dist < best {
				target, best, ok = e, dist, true
			}
		}
		g = sim.link_of(sim.group_links(s), g).next
	}
	return
}

// Whether a player's air shot can hit `e`: the candidates entity_collisions
// would test a player projectile against, bar the overlap itself.
air_shot_can_hit :: proc "contextless" (s: ^sim.State, e: sim.Entity) -> bool {
	if e.deleted || !e.hittable || e.state < 0 || e.appear_delay >= 1 {
		return false
	}
	return sim.prefab_is(s, sim.prefab_of(s, e), collision_system.air_shot_targets)
}

// Where to aim, relative to the shooter, to meet a target at `offset`
// moving by `vel` a step with a shot of `speed` a step: the earliest t > 0
// with |offset + vel t| = speed t, which is
//
//   (vel.vel - speed^2) t^2 + 2 (offset.vel) t + offset.offset = 0
//
// Straight at the target when no such t exists (it outruns the shot).
// Provisional: leads by the target's velocity alone, so a target that
// turns or accelerates is missed by as much as it changes.
aimed_intercept :: proc "contextless" (offset, vel: sim.Vec, speed: f32) -> sim.Vec {
	a := vel.x * vel.x + vel.y * vel.y - speed * speed
	b := 2 * (offset.x * vel.x + offset.y * vel.y)
	c := offset.x * offset.x + offset.y * offset.y
	t: f32 = -1
	if abs(a) < 1e-4 {
		if b < 0 {
			t = -c / b
		}
	} else if disc := b * b - 4 * a * c; disc >= 0 {
		root := math.sqrt(disc)
		t1, t2 := (-b - root) / (2 * a), (-b + root) / (2 * a)
		t = min(t1, t2) > 0 ? min(t1, t2) : max(t1, t2)
	}
	if t <= 0 {
		return offset
	}
	return offset + vel * t
}
