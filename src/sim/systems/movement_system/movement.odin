package movement_system

// Movement: G_Entity's movement AI (turning, hunting, fleeing, holding to a
// target) and the ways an entity follows its owner (locked, linked,
// orbiting, cyclic), and the move itself.

import "dr:sim"
import "dr:sim/lifecycle"

// G_Entity::DoMovementAI, as the stages it is made of. A fleeing entity
// steers for its flee target and does nothing else; the rest look for the
// nearest player, react to there being none, wander, keep to the play area
// and hunt, in the original's order, each for the entities its query
// names. An entity that starts to flee on the way skips what is left.

// DoMovementAI's flee path.
flee_steer_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	if e.fleeing {
		move_to_target(s, e)
		rotate_to_target(s, e, es.time)
	}
	return true
}

sense_players_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	if e.fleeing {
		return true
	}
	n := &es.nearest
	n.loc, n.dist, n.player, n.found = closest_active_player(s, e.loc)
	if !n.found {
		e.hunt_player = -1
	}
	return true
}

// Entities with Deleted_Without_Players.
alone_delete_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	if e.fleeing || es.nearest.found {
		return true
	}
	return lifecycle.entity_carry_on(s, e, true, false, es.time)
}

// Entities with Destructs_Without_Players.
alone_destruct_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	if e.fleeing || es.nearest.found {
		return true
	}
	return lifecycle.entity_carry_on(s, e, false, true, es.time)
}

// Entities with Flees_Without_Players.
alone_flee_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	if e.fleeing || es.nearest.found {
		return true
	}
	lifecycle.entity_flee(s, e, sim.step_component(s, e, es, Flees_Without_Players).flee)
	return true
}

// Entities with Cyclic_Motion.
cyclic_motion_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	if !e.fleeing {
		cyclic_motion(s, e)
	}
	return true
}

// Entities with Constrained_To_Play_Area.
constrain_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	if !e.fleeing {
		constrain_in_game_area(s, e)
	}
	return true
}

// Towards the nearest player, or holding off from it once in range, where
// reaching its range can change the entity's state.
hunt_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	if e.fleeing {
		return true
	}
	del, des := hunt(s, e, es.nearest, es.time)
	return lifecycle.entity_carry_on(s, e, del, des, es.time)
}

move_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	if !move_and_check_position(s, e.obj, 0x80, true) {
		lifecycle.entity_delete(e)
		return false
	}
	return true
}

// The ways of following the owner, in the original's order, for the
// entities with Locked_To_Owner, Linked_To_Owner and Orbits_Owner.
lock_to_owner_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	lock_to_owner(s, e)
	return true
}

link_to_owner_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	link_to_owner(s, e)
	return true
}

orbit_owner_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	orbit_owner(s, e)
	return true
}

// G_Entity::IsWithinGameArea: the entity's centre is on screen.
within_game_area :: proc "contextless" (s: ^sim.State, e: sim.Entity) -> bool {
	w := s.defs.perm_floats[sim.PF_VISIBLE_GAME_WIDTH]
	h := s.defs.perm_floats[sim.PF_VISIBLE_GAME_HEIGHT]
	return !(e.loc.x < 0) && !(w < e.loc.x) && !(e.loc.y < 0) && !(h < e.loc.y)
}

// G_Entity::Priv_DoRotationAsRequired: rotate unless a spawn volley is in
// progress (the state can pause rotation while spawning).
rotate_as_required :: proc(s: ^sim.State, e: sim.Entity, time: i32) -> bool {
	st := sim.state_of(s, e)
	if !st.do_rotate_to_target {
		e.rotating = false
		return true
	}
	if e.spawn_pause > 0 {
		e.spawn_pause -= 1
		if e.spawn_pause < 0 {
			e.spawn_pause = 0
		}
	}
	spawning := e.spawn_pause >= 1
	if !spawning {
		for &set, i in st.spawn_sets {
			info := &e.spawn_info[i]
			if set.spawn != sim.NONE && info.active && set.pause_any_rotation_while_spawning &&
			   info.left > 0 && info.left < info.volley {
				spawning = true
				break
			}
		}
	}
	if spawning {
		return false
	}
	return rotate_to_target(s, e, time)
}

// G_Entity::Priv_RotateToTargetLoc: turn one animation direction per frame
// delay towards the hunt target, the frame encoding the heading.
rotate_to_target :: proc(s: ^sim.State, e: sim.Entity, time: i32) -> bool {
	st := sim.state_of(s, e)
	if !st.do_rotate_to_target {
		e.rotating = false
		return true
	}
	if !e.fleeing {
		if e.hunt_player == -1 {
			e.rotating = false
			return false
		}
		e.rotating = true
	}
	if !(e.anim_time + st.frame_delay < time) {
		return false
	}
	want := sim.intercept_angle(sim.trunc_i32(e.loc.x), sim.trunc_i32(e.loc.y),
		sim.trunc_i32(e.hunt_target.x), sim.trunc_i32(e.hunt_target.y))
	if e.frame == lifecycle.frame_for_angle(s, e, want) {
		return true
	}
	have := lifecycle.angle_from_sprite(s, e)
	per_dir := st.frames_per_direction
	frames := per_dir * st.num_directions
	diff := want - have
	if diff > 180 {
		diff -= 360
	}
	if diff < -180 {
		diff += 360
	}
	if diff < 1 {
		for _ in 0 ..< per_dir {
			e.frame -= 1
			if e.frame < 0 {
				e.frame = frames - 1
			}
		}
	} else {
		for _ in 0 ..< per_dir {
			e.frame += 1
			if frames <= e.frame {
				e.frame = 0
			}
		}
	}
	e.anim_time = time
	e.dims_dirty = true
	e.has_frame_ptr = true
	return false
}

// The end of G_Entity::DoMovementAI, from the nearest player `n`.
hunt :: proc(s: ^sim.State, e: sim.Entity, n: sim.Sighting, time: i32) -> (delete, destroy: bool) {
	st := sim.state_of(s, e)
	target, dist, player, found := n.loc, n.dist, n.player, n.found
	hunting := false
	e.hunt_target = target
	e.hunt_player = player
	if found {
		if st.on_range == 0 || !(dist < st.on_range) {
			hunting = st.hunts
		} else {
			// In range: react.
			to := st.on_range_change_to
			if to == "Delete" {
				return true, false
			}
			if to == "Destroy" {
				return false, true
			}
			if to != "" && to != "none" {
				del, des := lifecycle.change_state(s, e, false, to, time)
				if del || des {
					return del, des
				}
				st = sim.state_of(s, e)
				if st.reverse_direction_on_reaction {
					reverse_from_target(s, e, target, dist)
				}
			}
			if !st.hold_position_to_target {
				hunting = st.hunts
			} else {
				hold_to_target(s, e, target)
				hunting = false
			}
		}
	}
	if !e.fleeing && hunting {
		move_to_target(s, e)
	} else {
		adjust_to_required_velocity(s, e)
	}
	return
}

// G_Game_Player_GetClosestActive: nearest player in play, by the original's
// integer-truncated distance. Ties keep the lower-numbered player.
closest_active_player :: proc "contextless" (s: ^sim.State, from: sim.Vec) -> (loc: sim.Vec, dist: f32, player: i32, found: bool) {
	player = -1
	for p, i in sim.players_of(s) {
		if p.state != .Playing {
			continue
		}
		d := p.loc - from
		r := sim.m_sqrt(sim.trunc_i32(d.x * d.x + d.y * d.y))
		if !found || r < dist {
			loc, dist, player, found = p.loc, r, p.number, true
		}
		_ = i
	}
	return
}

// G_Entity::Priv_MoveToTargetLoc: accelerate toward the target, capped.
move_to_target :: proc "contextless" (s: ^sim.State, e: sim.Entity) {
	st := sim.state_of(s, e)
	top, delta := st.max_speed, st.delta
	if e.fleeing {
		top, delta = st.flee_speed, st.flee_delta
	}
	e.vel_delta.x = e.loc.x < e.hunt_target.x ? delta : -delta
	e.vel_delta.y = e.loc.y < e.hunt_target.y ? delta : -delta
	e.vel.x += e.vel_delta.x
	if e.vel.x > top {
		e.vel.x = top
	} else if e.vel.x < -top {
		e.vel.x = -top
	}
	e.vel.y += e.vel_delta.y
	if e.vel.y > top {
		e.vel.y = top
	} else if e.vel.y < -top {
		e.vel.y = -top
	}
}

// G_Entity::Priv_AdjustToRequiredVelocity.
adjust_to_required_velocity :: proc(s: ^sim.State, e: sim.Entity) {
	if e.stationary {
		e.vel, e.vel_target, e.vel_delta = {}, {}, {}
		return
	}
	st := sim.state_of(s, e)
	// An orbit's speed is its angle's: see orbit_owner.
	if sim.entity_has(s, e, Orbits_Owner) {
		top := st.max_speed
		if e.vel.x < top {
			e.vel.x += st.delta
			if top < e.vel.x {
				e.vel.x = top
			}
		} else if e.vel.x > top {
			e.vel.x -= st.delta
			if e.vel.x < top {
				e.vel.x = top
			}
		}
		return
	}
	if e.vel.x < e.vel_target.x {
		e.vel.x += e.vel_delta.x
		if e.vel_target.x < e.vel.x {
			e.vel.x = e.vel_target.x
		}
	} else if e.vel.x > e.vel_target.x {
		e.vel.x += e.vel_delta.x
		if e.vel.x < e.vel_target.x {
			e.vel.x = e.vel_target.x
		}
	}
	if e.vel.y < e.vel_target.y {
		e.vel.y += e.vel_delta.y
		if e.vel_target.y < e.vel.y {
			e.vel.y = e.vel_target.y
		}
	} else if e.vel_target.y < e.vel.y {
		e.vel.y += e.vel_delta.y
		if e.vel.y < e.vel_target.y {
			e.vel.y = e.vel_target.y
		}
	}
}

// G_GameObject::MoveAndCheckPosition: move, then report whether the object
// is still within `margin` of the play area. Ground objects ride the scroll.
move_and_check_position :: proc "contextless" (s: ^sim.State, o: ^sim.Game_Object, margin: i32, generous: bool) -> bool {
	if !o.is_air {
		o.loc.y = f32(sim.single(s, sim.Bgnd).scrolled) + o.loc.y
	}
	o.loc += o.vel
	w, h := sim.view_width(s.defs), sim.view_height(s.defs)
	if generous {
		m := f32(margin)
		return -m <= f32(o.half.x) + o.loc.x &&
			o.loc.x - f32(o.half.x) <= f32(w + margin) &&
			-m <= o.loc.y &&
			o.loc.y - f32(o.half.y) <= f32(h + margin)
	}
	return !(f32(o.half.x) + o.loc.x < -32) &&
		o.loc.x - f32(o.half.x) <= f32(w + 32) &&
		!(f32(o.half.y) + o.loc.y < 0) &&
		!(f32(h) < o.loc.y - f32(o.half.y))
}

// FUN_0041bd90: sit at a fixed offset from the owner.
lock_to_owner :: proc "contextless" (s: ^sim.State, e: sim.Entity) {
	o, ok := sim.owner_loc(s, e)
	if ok && (o.x != e.loc.x || o.y != e.loc.y) {
		e.loc = {o.x + e.owner_offset.x, o.y + e.owner_offset.y}
	}
}

// FUN_0041be80: move by however far the owner moved since last step.
link_to_owner :: proc "contextless" (s: ^sim.State, e: sim.Entity) {
	o, ok := sim.owner_loc(s, e)
	if !ok {
		return
	}
	d := sim.Vec{e.owner_loc.x - o.x, e.owner_loc.y - o.y}
	e.loc = {e.loc.x - d.x, e.loc.y - d.y}
	e.owner_loc = o
}

// FUN_0041bf70: circle the owner, the angle advancing by the (truncated)
// horizontal speed each step.
orbit_owner :: proc "contextless" (s: ^sim.State, e: sim.Entity) {
	o, ok := sim.owner_loc(s, e)
	if !ok || (o.x == e.loc.x && o.y == e.loc.y) {
		return
	}
	next: sim.Vec
	step := sim.trunc_i32(e.vel.x)
	if e.orbit_radius == 0 || step == 0 {
		next = {o.x + e.owner_offset.x, o.y + e.owner_offset.y}
	} else {
		e.orbit_angle += step
		if e.orbit_angle >= 360 {
			e.orbit_angle -= 360
		} else if e.orbit_angle < 0 {
			e.orbit_angle += 360
		}
		p := sim.vector_from_angle_and_speed(e.orbit_angle, e.orbit_radius)
		next = {o.x + p.x, o.y + p.y}
	}
	e.loc = next
	e.owner_offset = {e.loc.x - o.x, e.loc.y - o.y}
}

// G_Entity::Priv_DoCyclicMotion: wander, re-drawing a speed limit each step
// and reversing the acceleration whenever the velocity passes it.
cyclic_motion :: proc "contextless" (s: ^sim.State, e: sim.Entity) {
	st := sim.state_of(s, e)
	top := sim.trunc_i32(st.max_speed)
	whole := sim.roll_int(s, lifecycle.halve(top), top, 0x416032)
	frac := sim.roll_int(s, 1, 100, 0x41604f)
	limit := f32(whole) + f32(frac) / 100
	flip :: proc "contextless" (v: ^f32) {
		v^ = transmute(f32)(transmute(u32)v^ ~ 0x8000_0000)
	}
	if limit < e.vel.x {
		e.vel.x = limit
		flip(&e.vel_delta.x)
	}
	if e.vel.x < -limit {
		e.vel.x = -limit
		flip(&e.vel_delta.x)
	}
	if limit < e.vel.y {
		e.vel.y = limit
		flip(&e.vel_delta.y)
	}
	if e.vel.y < -limit {
		e.vel.y = -limit
		flip(&e.vel_delta.y)
	}
	e.vel += e.vel_delta
	e.vel_target = e.vel
}

// G_Entity::Priv_ConstrainInGameArea: bounce off the edges of the play area,
// reversing velocity, acceleration and target velocity together. The left and
// right edges use the full width; the top and bottom use half the height.
constrain_in_game_area :: proc "contextless" (s: ^sim.State, e: sim.Entity) {
	w, h := sim.view_width(s.defs), sim.view_height(s.defs)
	flip :: proc "contextless" (v: ^f32) {
		v^ = transmute(f32)(transmute(u32)v^ ~ 0x8000_0000)
	}
	bounce_x :: proc "contextless" (e: sim.Entity) {
		flip(&e.vel.x)
		flip(&e.vel_delta.x)
		flip(&e.vel_target.x)
	}
	if e.loc.x < -32 {
		flip(&e.vel.x)
		e.loc.x = -32
		flip(&e.vel_delta.x)
		flip(&e.vel_target.x)
	}
	if f32(w + 32) < f32(e.dims.x) + e.loc.x {
		e.loc.x = f32(w - e.dims.x + 32)
		bounce_x(e)
	}
	if e.loc.y - f32(e.half.y) < 0 {
		flip(&e.vel.y)
		e.loc.y = f32(e.half.y)
		flip(&e.vel_delta.y)
		flip(&e.vel_target.y)
	}
	if f32(h) < f32(e.half.y) + e.loc.y {
		flip(&e.vel.y)
		e.loc.y = f32(h - e.half.y)
		flip(&e.vel_delta.y)
		flip(&e.vel_target.y)
	}
}

// G_Entity::Priv_HoldToTarget: close on the target at the state's hold speed.
hold_to_target :: proc "contextless" (s: ^sim.State, e: sim.Entity, target: sim.Vec) {
	st := sim.state_of(s, e)
	top, delta := st.hold_max_speed, st.hold_delta
	e.vel_delta.x = e.loc.x < target.x ? delta : -delta
	e.vel_delta.y = e.loc.y < target.y ? delta : -delta
	e.vel.x += e.vel_delta.x
	if e.vel.x > top {
		e.vel.x = top
	} else if e.vel.x < -top {
		e.vel.x = -top
	}
	e.vel.y += e.vel_delta.y
	if e.vel.y > top {
		e.vel.y = top
	} else if e.vel.y < -top {
		e.vel.y = -top
	}
}

// G_Entity::Priv_ReverseFromTarget: head away from the target at full speed.
reverse_from_target :: proc "contextless" (s: ^sim.State, e: sim.Entity, target: sim.Vec, dist: f32) {
	d := target - e.loc
	if dist != 0 {
		d /= dist
	}
	top := sim.state_of(s, e).max_speed
	e.vel_target = {-(d.x * top), -(d.y * top)}
}
