package collision_system

// The collision stages of G_EG_Process: an entity touching a player, a
// ground unit meeting wreckage, and shots against what they can hit.

import "dr:sim"
import "dr:sim/lifecycle"
import "dr:sim/systems/debris_system"

// Touching a player: both take damage, or the player collects a pickup.
player_contact_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	st, u, b := es.st, es.u, es.bounds
	w, h := sim.view_width(s.defs), sim.view_height(s.defs)
	if sim.players_in_play(s) > 0 && st.collides && !u.harmless_to_players && st.collides_with_players &&
	   b.right > -33 && b.left <= w + 32 && b.bottom >= 0 && b.top <= h {
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
				if st.pass_hits_to_owner && sim.ref_valid(s, e.owner) {
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

// A ground unit that runs into wreckage stops there.
ground_obstacles_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	if !e.stationary && !e.is_air && es.u.collides_with_ground_obstacles {
		if debris_system.debris_hits(s, lifecycle.object_bounds(e.obj)) {
			e.vel = {}
			e.stationary = true
			if es.u.destruct_create_obstacle {
				debris_system.debris_new(s, lifecycle.object_bounds(e.obj))
			}
		}
	}
	return true
}

shot_collisions_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	if !e.deleted && es.st.collides {
		entity_collisions(s, e)
	}
	return true
}

// U_Math_DoCircleCollisionDetection.
circles_collide :: proc "contextless" (a: sim.Vec, ra: f32, b: sim.Vec, rb: f32) -> bool {
	d := a - b
	return sim.m_sqrt(sim.trunc_i32(d.x * d.x + d.y * d.y)) < ra + rb
}

// FUN_0041b920: collisions between a "harmless to players" entity (player
// shots and their kin) and the entities it can hit. Candidate filtering and
// the overlap test are ported; what a hit does is not yet.
entity_collisions :: proc(s: ^sim.State, e: sim.Entity) {
	w := sim.single(s, sim.Pool)
	u := sim.unit_of(s, e)
	me := lifecycle.object_bounds(e.obj)
	if u.player_projectile && me.bottom < 0 {
		return
	}
	n := w.active.count
	gc := sim.Cursor{sim.NO_LINK}
	for _ in 0 ..< n {
		gi := sim.list_next(&w.active, sim.group_links(s), &gc)
		m := sim.group_at(s, gi).entities.count
		ec := sim.Cursor{sim.NO_LINK}
		for _ in 0 ..< m {
			oi := sim.list_next(&sim.group_at(s, gi).entities, sim.entity_links(s), &ec)
			o := sim.entity_at(s, oi)
			ou := sim.unit_of(s, o)
			ost := sim.state_of(s, o)
			if !ost.collides || o.deleted || !o.hittable || o.number == e.number {
				continue
			}
			if ou.is_ground_based != u.is_ground_based || !u.harmless_to_players || ou.harmless_to_players {
				continue
			}
			if o.appear_delay >= 1 {
				continue
			}
			if u.player_projectile {
				if !ou.can_be_hit_by_player_projectile {
					continue
				}
			} else if !(ou.can_be_hit_by_player_projectile && ou.player_projectile) {
				continue
			}
			ob := lifecycle.object_bounds(o.obj)
			if ou.player_projectile && ob.bottom < 0 {
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
}
