package collision_system

// The collision stages of G_EG_Process: an entity touching a player, a
// ground unit meeting wreckage, and shots against what they can hit.

import "dr:sim"
import "dr:sim/lifecycle"
import "dr:sim/systems/debris_system"

// Touching a player: both take damage, or the player collects a pickup.
// Entities with Collides and Collides_With_Players, not Harmless_To_Players.
player_contact_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	u, b := es.u, es.bounds
	w, h := sim.view_width(s.defs), sim.view_height(s.defs)
	if sim.players_in_play(s) > 0 && b.right > -33 && b.left <= w + 32 && b.bottom >= 0 && b.top <= h {
		for p in sim.players_of(s) {
			if p.state != .Playing || e.deleted {
				continue
			}
			pb := lifecycle.object_bounds(p.obj)
			if !(pb.top <= b.bottom && b.top <= pb.bottom && pb.left <= b.right && b.left <= pb.right) {
				continue
			}
			if !circles_collide(p.loc, f32(pb.bottom - pb.top) / 2, e.loc, f32(lifecycle.halve(b.bottom - b.top))) {
				continue
			}
			if u.pickup_type == sim.NONE {
				// Both sides take damage; a state can pass hits to its owner.
				hit_owner := false
				if sim.prefab_has(s, es.prefab, Passes_Hits_To_Owner) && sim.ref_valid(s, e.owner) {
					entity_hit(s, sim.entity_at(s, e.owner.index), s.defs.perm_floats[0xa1], p.number, sim.single(s, sim.Clock).time)
					hit_owner = true
				}
				if !hit_owner {
					entity_hit(s, e, s.defs.perm_floats[0xa1], p.number, sim.single(s, sim.Clock).time)
				}
				player_hit(s, p, u.damage, sim.single(s, sim.Clock).time)
			} else if player_collect(s, p, e) {
				lifecycle.entity_destroy(s, e, p.number, sim.single(s, sim.Clock).time)
				e.killed_by_player = true
			}
		}
	}
	return !e.deleted
}

// A ground unit that runs into wreckage stops there. Entities with
// Blocked_By_Wreckage.
ground_obstacles_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	if !e.stationary && !e.is_air {
		if debris_system.debris_hits(s, lifecycle.object_bounds(e.obj)) {
			e.vel = {}
			e.stationary = true
			if sim.prefab_component(s, es.prefab, Blocked_By_Wreckage).becomes_wreckage {
				debris_system.debris_new(s, lifecycle.object_bounds(e.obj))
			}
		}
	}
	return true
}

// Shots and their kin: entities with Collides and Harmless_To_Players. (The
// original tests every colliding entity, and finds nothing for one that is
// not harmless to players.)
shot_collisions_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	if !e.deleted {
		entity_collisions(s, e, es)
	}
	return true
}

// U_Math_DoCircleCollisionDetection.
circles_collide :: proc "contextless" (a: sim.Vec, ra: f32, b: sim.Vec, rb: f32) -> bool {
	d := a - b
	return sim.m_sqrt(sim.trunc_i32(d.x * d.x + d.y * d.y)) < ra + rb
}

// Whether a shot can hit a target, by their prefabs: one that collides and
// is not a shot itself, on the ground if the shot is, and -- for a shot
// that is not a player's -- only a player's shot it can hit.
shot_hits :: proc "contextless" (s: ^sim.State, shot, target: i32) -> bool {
	if !sim.prefab_is(s, target, shot_targets) {
		return false
	}
	if sim.prefab_is(s, shot, ground_based) != sim.prefab_is(s, target, ground_based) {
		return false
	}
	return sim.prefab_is(s, shot, player_projectile) || sim.prefab_is(s, target, player_projectile)
}

// FUN_0041b920: collisions between a "harmless to players" entity (player
// shots and their kin) and the entities it can hit, in group order.
entity_collisions :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) {
	me := lifecycle.object_bounds(e.obj)
	if sim.prefab_is(s, es.prefab, player_projectile) && me.bottom < 0 {
		return
	}
	walk := sim.cursor_walk(s, fixed = true)
	for o in sim.cursor_next(&walk) {
		if o.deleted || !o.hittable || o.number == e.number || o.appear_delay >= 1 {
			continue
		}
		op := sim.prefab_of(s, o)
		if !shot_hits(s, es.prefab, op) {
			continue
		}
		ob := lifecycle.object_bounds(o.obj)
		if sim.prefab_is(s, op, player_projectile) && ob.bottom < 0 {
			continue
		}
		if !(ob.top <= me.bottom && me.top <= ob.bottom && ob.left <= me.right && me.left <= ob.right) {
			continue
		}
		if circles_collide(e.loc, f32(lifecycle.halve(me.bottom - me.top)), o.loc, f32(lifecycle.halve(ob.bottom - ob.top))) {
			collide_entities(s, e, o, sim.single(s, sim.Clock).time)
			if e.deleted {
				return
			}
		}
	}
}
