package sim

// G_EG_Process: one step for every entity, in group order.
//
// Returns true when some entity's state asks for vertical scrolling to pause.
// Branches not ported yet mark themselves with `unported`.
eg_process :: proc(s: ^State, time: i32) -> (pause_scrolling: bool) {
	w := &s.world
	if w.active.count <= 0 {
		return
	}

	gc := Cursor{NO_LINK}
	for gi_n: i32 = 0; gi_n < w.active.count; gi_n += 1 {
		gi := list_next(&w.active, w.group_links[:], &gc)
		ec := Cursor{NO_LINK}
		for n: i32 = 0; n < w.groups[gi].entities.count; n += 1 {
			ei := list_next(&w.groups[gi].entities, w.entity_links[:], &ec)
			if process_entity(s, ei, time) {
				pause_scrolling = true
			}
		}
	}
	sweep_deleted(s)
	return
}

// The body of G_EG_Process's inner loop for one entity.
@(private = "file")
process_entity :: proc(s: ^State, ei: i32, time: i32) -> (pause: bool) {
	e := entity_at(s, ei)
	st := state_of(s, e)
	u := unit_of(s, e)

	e.appear_delay -= 1
	if e.appear_delay >= 1 {
		e.state_time = time
		return
	}

	// State particles.
	if st.particles != NONE {
		due := false
		if !st.particles_repeat {
			due = e.particle_count == 0
		} else {
			due = e.particle_time == 0 || e.particle_time + st.particles_repeat_delay <= time
		}
		if due {
			if st.particles_max_num_bursts == 0 || e.particle_count < st.particles_max_num_bursts {
				particle_burst(s, e.loc, st.particles_color, st.particles, u.is_ground_based)
			}
			e.particle_count += 1
			e.particle_time = time
		}
	}

	// State entry sound.
	play := false
	if st.entry_sound != NONE {
		if !st.sound_loop {
			if e.entry_counts[e.state] == 1 {
				play = e.sound_count == 0
			} else if st.sound_repeat_on_state_change {
				play = e.sound_count == 0
			}
		} else if e.sound_time == 0 || e.sound_time + st.sound_loop_delay <= time {
			play = true
		}
	}
	if play {
		if st.sound_allow_only_one_instance {
			unported(s, 0x418614) // U_Sound_IsPlaying: needs a sound-duration model
		}
		if st.sound_max_num_to_play == 0 || e.sound_count < st.sound_max_num_to_play {
			sound_play(s, state_sound(st), true)
		}
		e.sound_count += 1
		e.sound_time = time
	}

	// The state timer.
	if time == e.state_time + e.timer {
		to := st.on_timer_change_to
		switch {
		case to == "Delete":
			e.deleted = true
			e.target_player = -1
			return
		case to == "Destroy":
			entity_destroy(s, e, -1, time)
			return
		case to != "" && to != "none":
			del, des := change_state(s, e, false, to, time)
			if del {
				e.deleted = true
				e.target_player = -1
				return
			}
			if des {
				entity_destroy(s, e, -1, time)
				return
			}
			st = state_of(s, e)
		}
	}

	if st.pause_vertical_scrolling {
		pause = true
	}
	entity_animate(s, e, time)

	if len(st.rules) > 0 {
		del, des := process_rules(s, e, time)
		if del {
			e.deleted = true
			e.target_player = -1
			return
		}
		if des {
			entity_destroy(s, e, -1, time)
			return
		}
		st = state_of(s, e)
	}

	e.visibility_target = f32(st.required_visibility_percent)
	e.visibility_delta = f32(st.visibility_delta_percent)
	e.colorise = st.do_colorise
	e.tint_target = f32(st.tint_percent)
	e.tint_delta = f32(st.tint_delta_percent)
	e.tint_color = color_1555(st.tint_color)
	adjust_visibility_and_tinting(&e.obj)
	e.hittable = true
	if e.visibility < 100 && !u.hittable_when_invisible {
		e.hittable = false
	}
	e.scale_target = f32(st.required_scale_percent) / 100
	e.scale_delta = f32(st.scale_delta_percent) / 100
	do_scaling(&e.obj)
	calculate_dimensions(s, &e.obj)
	glow_process(&e.obj)
	if (st.use_owners_visibility || st.use_owners_scale || st.visually_reflect_owner_hits) &&
	   ref_valid(s, e.owner) {
		// FUN_0041b5d0: follow the owner's look (the hit glow is presentation).
		o := entity_at(s, e.owner.index)
		if st.use_owners_visibility {
			e.visibility = o.visibility
		}
		if st.use_owners_scale {
			e.dims_dirty = o.dims_dirty
			e.scale, e.scale_target, e.scale_delta = o.scale, o.scale_target, o.scale_delta
			calculate_dimensions(s, &e.obj)
		}
	}

	if st.destruct_if_vertical_scrolling_not_paused && s.bgnd.speed != 0 {
		entity_destroy(s, e, -1, time)
		return
	}
	del, des := movement_ai(s, e, time)
	if del {
		e.deleted = true
		e.target_player = -1
		return
	}
	if des {
		entity_destroy(s, e, -1, time)
		return
	}
	if !move_and_check_position(s, &e.obj, 0x80, true) {
		e.deleted = true
		e.target_player = -1
		return
	}
	if st.lock_to_owner_loc {
		lock_to_owner(s, e)
	}
	if st.link_to_owner_loc {
		link_to_owner(s, e)
	}
	if st.orbit_owner {
		orbit_owner(s, e)
	}
	spawn_control(s, e, time)
	if e.deleted {
		return
	}
	b := object_bounds(&e.obj)
	w, h := view_width(s.defs), view_height(s.defs)
	if players_in_play(s) > 0 && st.collides && !u.harmless_to_players && st.collides_with_players &&
	   b.right > -33 && b.left <= w + 32 && b.bottom >= 0 && b.top <= h {
		for &p in s.players {
			if p.state != .Playing || e.deleted {
				continue
			}
			pb := object_bounds(&p.obj)
			if !(pb.top <= b.bottom && b.top <= pb.bottom && pb.left <= b.right && b.left <= pb.right) {
				continue
			}
			if !circles_collide(p.loc, f32(pb.bottom - pb.top) / 2, e.loc, f32(halve(b.bottom - b.top))) {
				continue
			}
			if u.pickup_type == NONE {
				// Both sides take damage; a state can pass hits to its owner.
				hit_owner := false
				if st.pass_hits_to_owner && ref_valid(s, e.owner) {
					entity_hit(s, entity_at(s, e.owner.index), s.defs.perm_floats[0xa1], p.number, s.time)
					hit_owner = true
				}
				if !hit_owner {
					entity_hit(s, e, s.defs.perm_floats[0xa1], p.number, s.time)
				}
				player_hit(s, &p, u.damage, s.time)
			} else if player_collect(s, &p, e) {
				entity_destroy(s, e, p.number, s.time)
				e.killed_by_player = true
			}
		}
	}
	if e.deleted {
		return
	}
	if st.motion_blur_required && e.sprite != NONE {
		gap := random_int(&s.rng, st.motion_blur_min_time_between_blurs, st.motion_blur_max_time_between_blurs, 0x418d92)
		if e.blur_time + gap < time {
			e.blur_time = time
			blur_spawn(s, &e.obj, st)
		}
	}
	if !u.harmless_to_players && u.is_ground_based && u.can_be_hit_by_player_projectile && st.is_targetable {
		// Crosshair highlighting: presentation only.
	}
	if !e.stationary && !e.is_air && u.collides_with_ground_obstacles {
		if debris_hits(s, object_bounds(&e.obj)) {
			e.vel = {}
			e.stationary = true
			if u.destruct_create_obstacle {
				debris_new(s, object_bounds(&e.obj))
			}
		}
	}
	if !e.deleted && st.collides {
		entity_collisions(s, e)
	}
	return
}

players_in_play :: proc "contextless" (s: ^State) -> (n: i32) {
	for &p in s.players {
		if p.state == .Playing {
			n += 1
		}
	}
	return
}

// U_Math_DoCircleCollisionDetection.
circles_collide :: proc "contextless" (a: Vec, ra: f32, b: Vec, rb: f32) -> bool {
	d := a - b
	return m_sqrt(trunc_i32(d.x * d.x + d.y * d.y)) < ra + rb
}

// FUN_0041b920: collisions between a "harmless to players" entity (player
// shots and their kin) and the entities it can hit. Candidate filtering and
// the overlap test are ported; what a hit does is not yet.
entity_collisions :: proc(s: ^State, e: ^Entity) {
	w := &s.world
	u := unit_of(s, e)
	me := object_bounds(&e.obj)
	if u.player_projectile && me.bottom < 0 {
		return
	}
	n := w.active.count
	gc := Cursor{NO_LINK}
	for _ in 0 ..< n {
		gi := list_next(&w.active, w.group_links[:], &gc)
		m := w.groups[gi].entities.count
		ec := Cursor{NO_LINK}
		for _ in 0 ..< m {
			oi := list_next(&w.groups[gi].entities, w.entity_links[:], &ec)
			o := entity_at(s, oi)
			ou := unit_of(s, o)
			ost := state_of(s, o)
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
			ob := object_bounds(&o.obj)
			if ou.player_projectile && ob.bottom < 0 {
				continue
			}
			if !(ob.top <= me.bottom && me.top <= ob.bottom && ob.left <= me.right && me.left <= ob.right) {
				continue
			}
			if circles_collide(e.loc, f32(halve(me.bottom - me.top)), o.loc, f32(halve(ob.bottom - ob.top))) {
				collide_entities(s, e, o, s.time)
				if e.deleted {
					return
				}
			}
		}
	}
}

// G_Entity::SpawnControl: run the current state's spawn sets.
spawn_control :: proc(s: ^State, e: ^Entity, time: i32) {
	record_event(s, Event{kind = .Spawn_Control, unit = unit_of(s, e).id, number = e.number})
	rotate_as_required(s, e, time)
	if !e.spawning {
		return
	}
	st := state_of(s, e)
	for &set, i in st.spawn_sets {
		info := &e.spawn_info[i]
		if set.spawn == NONE || !info.active || info.delay < 0 || (e.fleeing && !set.spawn_if_fleeing) {
			continue
		}
		if set.dont_spawn_offscreen && info.left >= 1 && info.left >= info.volley && !within_game_area(s, e) {
			info.left = 0
			continue
		}
		fire := false
		if info.left < 1 {
			if !set.repeat_spawns {
				info.active = false
			} else if info.last + info.delay <= time {
				// A new volley: timings re-drawn, nothing spawned this step.
				info.last = time
				info.gap = random_int(&s.rng, set.delay_between_entities_min, set.delay_between_entities_max, 0x414c7c)
				info.volley = random_int(&s.rng, set.num_in_volley_min, set.num_in_volley_max, 0x414c91)
				info.left = info.volley
				info.delay = random_int(&s.rng, set.rate_min, set.rate_max, 0x414cac)
				if set.pause_any_rotation_while_spawning && e.spawn_pause < set.time_to_pause_rotation_after_spawning {
					e.spawn_pause = set.time_to_pause_rotation_after_spawning
				}
			}
		} else {
			if info.gap > 0 {
				info.gap -= 1
			}
			if info.gap < 1 {
				fire = true
				info.left -= 1
				info.gap = random_int(&s.rng, set.delay_between_entities_min, set.delay_between_entities_max, 0x414c39)
			}
		}
		if fire {
			spawn_child(s, e, &set)
		}
	}
}

// The spawn at the end of SpawnControl: place the child relative to its
// parent, optionally rotated with the parent's facing.
@(private = "file")
spawn_child :: proc(s: ^State, e: ^Entity, set: ^Spawn_Set_Def) {
	ci := unit_index(s.defs, set.spawn)
	child: ^Unit = ci >= 0 ? &s.defs.units[ci] : nil
	// Terrain effects only come from mobile parents that allow them.
	if child != nil && child.terrain_effect && !(!e.stationary && e.terrain_effects) {
		return
	}
	req := spawn_request(set.spawn)
	scaled_offset := child != nil && e.scale != 1 && child.adjust_initial_loc_for_owner_scale
	explicit := false
	if !set.adjust_offset_for_unit_rotation {
		if !set.absolute_coordinates {
			req.loc = e.loc
		}
		done := false
		if scaled_offset {
			req.loc.x = f32(set.x_offset) * e.scale + req.loc.x
			req.loc.y = req.loc.y + f32(set.y_offset) * e.scale
			done = true
		}
		if !set.absolute_coordinates {
			if !done {
				req.loc += {f32(set.x_offset), f32(set.y_offset)}
			}
		} else {
			req.loc = {f32(set.x_offset), f32(set.y_offset)}
		}
	} else {
		a := angle_from_sprite(s, e)
		if set.set_heading {
			a += set.heading_degrees
			if a > 359 {
				a -= 360
			}
			explicit = true
			req.heading = a
		}
		c, sn := m_cos(a), m_sin(a)
		ox, oy: i32
		if scaled_offset {
			x, y := f32(set.x_offset) * e.scale, f32(set.y_offset) * e.scale
			ox, oy = trunc_i32(x * c - y * sn), trunc_i32(x * sn + y * c)
		} else {
			x, y := f32(set.x_offset), f32(set.y_offset)
			ox, oy = trunc_i32(x * c - y * sn), trunc_i32(x * sn + y * c)
		}
		req.loc = {f32(ox) + e.loc.x, f32(oy) + e.loc.y}
	}
	req.explicit_heading = set.set_heading
	if !explicit {
		req.heading = set.heading_degrees
	}
	req.owner = {e.pool_index, e.number}
	req.owner_player = e.owner_player
	req.stationary = set.stationary_option
	req.terrain_effects = set.terrain_effects_option
	eg_request_spawn(s, req)
}

// G_Entity::GetAngleFromSpriteInfo: the heading the current frame depicts.
angle_from_sprite :: proc "contextless" (s: ^State, e: ^Entity) -> i32 {
	if e.state < 0 {
		return 0
	}
	st := state_of(s, e)
	if st.num_directions == 1 {
		return (360 / st.frames_per_direction) * e.frame
	}
	d := max(e.frame / st.frames_per_direction, 0)
	return (360 / st.num_directions) * d
}

// G_Entity::IsWithinGameArea: the entity's centre is on screen.
within_game_area :: proc "contextless" (s: ^State, e: ^Entity) -> bool {
	w := s.defs.perm_floats[PF_VISIBLE_GAME_WIDTH]
	h := s.defs.perm_floats[PF_VISIBLE_GAME_HEIGHT]
	return !(e.loc.x < 0) && !(w < e.loc.x) && !(e.loc.y < 0) && !(h < e.loc.y)
}

// G_Entity::Priv_DoRotationAsRequired: rotate unless a spawn volley is in
// progress (the state can pause rotation while spawning).
rotate_as_required :: proc(s: ^State, e: ^Entity, time: i32) -> bool {
	st := state_of(s, e)
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
			if set.spawn != NONE && info.active && set.pause_any_rotation_while_spawning &&
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
rotate_to_target :: proc(s: ^State, e: ^Entity, time: i32) -> bool {
	st := state_of(s, e)
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
	want := intercept_angle(trunc_i32(e.loc.x), trunc_i32(e.loc.y),
		trunc_i32(e.hunt_target.x), trunc_i32(e.hunt_target.y))
	if e.frame == frame_for_angle(s, e, want) {
		return true
	}
	have := angle_from_sprite(s, e)
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

// G_Entity::DoMovementAI.
movement_ai :: proc(s: ^State, e: ^Entity, time: i32) -> (delete, destroy: bool) {
	if e.fleeing {
		// DoMovementAI's flee path: steer to the flee target and rotate.
		move_to_target(s, e)
		rotate_to_target(s, e, time)
		return
	}
	st := state_of(s, e)
	u := unit_of(s, e)
	target, dist, player, found := closest_active_player(s, e.loc)
	if !found {
		e.hunt_player = -1
		if st.delete_on_no_active_players {
			return true, false
		}
		if st.destruct_on_no_active_players {
			return false, true
		}
		if u.flees_north_on_no_active_players {
			entity_flee(s, e, res_id("nora"))
			return
		}
		if u.flees_south_on_no_active_players {
			entity_flee(s, e, res_id("sora"))
			return
		}
	}
	if st.cyclic_motion {
		cyclic_motion(s, e)
	}
	if u.constrain_in_game_area {
		constrain_in_game_area(s, e)
	}
	hunt := false
	e.hunt_target = target
	e.hunt_player = player
	if found {
		if st.on_range == 0 || !(dist < st.on_range) {
			hunt = st.hunts
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
				del, des := change_state(s, e, false, to, time)
				if del || des {
					return del, des
				}
				st = state_of(s, e)
				if st.reverse_direction_on_reaction {
					reverse_from_target(s, e, target, dist)
				}
			}
			if !st.hold_position_to_target {
				hunt = st.hunts
			} else {
				hold_to_target(s, e, target)
				hunt = false
			}
		}
	}
	if !e.fleeing && hunt {
		move_to_target(s, e)
	} else {
		adjust_to_required_velocity(s, e)
	}
	return
}

// G_Game_Player_GetClosestActive: nearest player in play, by the original's
// integer-truncated distance. Ties keep the lower-numbered player.
closest_active_player :: proc "contextless" (s: ^State, from: Vec) -> (loc: Vec, dist: f32, player: i32, found: bool) {
	player = -1
	for &p, i in s.players {
		if p.state != .Playing {
			continue
		}
		d := p.loc - from
		r := m_sqrt(trunc_i32(d.x * d.x + d.y * d.y))
		if !found || r < dist {
			loc, dist, player, found = p.loc, r, p.number, true
		}
		_ = i
	}
	return
}

// G_Entity::Priv_MoveToTargetLoc: accelerate toward the target, capped.
move_to_target :: proc "contextless" (s: ^State, e: ^Entity) {
	st := state_of(s, e)
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
adjust_to_required_velocity :: proc "contextless" (s: ^State, e: ^Entity) {
	if e.stationary {
		e.vel, e.vel_target, e.vel_delta = {}, {}, {}
		return
	}
	st := state_of(s, e)
	if st.orbit_owner {
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
move_and_check_position :: proc "contextless" (s: ^State, o: ^Game_Object, margin: i32, generous: bool) -> bool {
	if !o.is_air {
		o.loc.y = f32(s.bgnd.scrolled) + o.loc.y
	}
	o.loc += o.vel
	w, h := view_width(s.defs), view_height(s.defs)
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

// FUN_0041b2d0: remove deleted entities, and groups that have emptied.
sweep_deleted :: proc(s: ^State) {
	w := &s.world
	n := w.active.count
	gc := Cursor{NO_LINK}
	groups: for _ in 0 ..< n {
		gi := list_next(&w.active, w.group_links[:], &gc)
		count := w.groups[gi].entities.count
		ec := Cursor{NO_LINK}
		for k: i32 = 0; k < count; k += 1 {
			ei := list_next(&w.groups[gi].entities, w.entity_links[:], &ec)
			e := entity_at(s, ei)
			if !e.deleted {
				continue
			}
			u := unit_of(s, e)
			if u.include_in_ground_accuracy_count {
				w.ground_targets -= 1
			}
			// The wreck is burned into the map as the entity is swept up, so
			// it stays where it fell and scrolls with the ground.
			if u.destruct_draw_to_terrain {
				stamp_object(s, &e.obj, u.casts_shadows)
			}
			if e.destroyed {
				if state_of(s, e).destroy_owner_on_destruction && ref_valid(s, e.owner) {
					o := entity_at(s, e.owner.index)
					if !o.deleted {
						entity_destroy(s, o, e.target_player, s.time)
					}
				}
			}
			if u.deletion_spawn != NONE && !e.destroyed && can_spawn_on_media(s, e) {
				spawn_from(s, e, u.deletion_spawn)
			}
			group_emptied := remove_from_group(s, gi, e, e.destroyed, e.target_player != -1)
			list_remove(&w.groups[gi].entities, w.entity_links[:], ei, &ec)
			entity_free(w, ei)
			if group_emptied && w.groups[gi].unit != PERM_GROUP_UNIT {
				list_remove(&w.active, w.group_links[:], gi, &gc)
				group_free(w, gi)
				continue groups
			}
		}
	}
}

// FUN_0041ae10: account for an entity leaving its group. Returns true when
// the group has no entities left (and is not PERM).
remove_from_group :: proc(s: ^State, gi: i32, e: ^Entity, destroyed, by_player: bool) -> bool {
	g := &s.world.groups[gi]
	u := unit_of(s, e)
	if e.has_spawn_info {
		if destroyed && u.destruct_destroy_children {
			children_follow(s, e, true)
		}
		if u.destruct_delete_children {
			children_follow(s, e, false)
		}
	}
	all_killed := false
	if destroyed {
		g.killed += 1
		all_killed = g.killed == g.count
	}
	if by_player && destroyed && !e.killed_by_player {
		if u.destruct_coin != NONE && u.destruct_num_coins_to_release > 0 {
			for _ in 0 ..< u.destruct_num_coins_to_release {
				spawn_from(s, e, u.destruct_coin)
			}
		}
		if g.unit != PERM_GROUP_UNIT && all_killed && u.destruct_coin_on_group_kill != NONE {
			spawn_from(s, e, u.destruct_coin_on_group_kill)
		}
	}
	// Destroy is a no-op for an entity the sweep already marked deleted, but
	// not for a child pulled in by children_follow.
	if destroyed {
		entity_destroy(s, e, e.target_player, s.time)
	}
	e.deleted = true
	g.total -= 1
	return g.total < 1 && g.unit != PERM_GROUP_UNIT
}

// G_Entity::ProcessRules: the first rule whose condition holds changes state.
//
// A rule's "action" is a state name handed to ChangeState; one that names no
// state of this unit silently does nothing, which is why most shipped actions
// look inert. Rules whose unit id is unknown are skipped (the original logs
// "FILE: Unknown Rule Unit ID" and blanks the id, with the same effect).
process_rules :: proc(s: ^State, e: ^Entity, time: i32) -> (delete, destroy: bool) {
	st := state_of(s, e)
	for &r in st.rules {
		if r.unit == NONE || unit_index(s.defs, r.unit) < 0 || r.condition == 0 {
			continue
		}
		hit := false
		switch r.condition - 1 {
		case 0:
			hit = any_entity_of(s, r.unit, e.loc, r.range, true)
		case 1:
			hit = !any_entity_of(s, r.unit, e.loc, r.range, true)
		case 2:
			hit = any_entity_of(s, r.unit, e.loc, r.range, false)
		case 3:
			hit = !any_entity_of(s, r.unit, e.loc, r.range, false)
		case 4:
			hit = !any_destroyable(s, air = true)
		case 5:
			hit = !any_destroyable(s, air = false)
		case 6:
			hit = !any_destroyable(s, air = true) && !any_destroyable(s, air = false)
		case 7:
			hit = players_in_play(s) == 0
		case 8, 9:
			// G_Entity::Priv_CheckWithinRangeOfPlayers.
			within := false
			if r.range != 0 {
				_, dist, _, found := closest_active_player(s, e.loc)
				within = found && dist < f32(r.range)
			}
			hit = r.condition - 1 == 8 ? within : !within
		case 10:
			hit = e.anim_done
		case 11:
			hit = e.visibility == e.visibility_target
		case 12:
			hit = e.tint == e.tint_target
		case 13:
			hit = e.scale == e.scale_target
		case 14:
			hit = r.range == count_appeared(s, r.unit)
		case 15:
			hit = count_appeared(s, r.unit) < r.range
		case 16:
			hit = r.range < count_appeared(s, r.unit)
		}
		if hit {
			return change_state(s, e, false, r.action, time)
		}
	}
	return
}

// G_EG_RuleCondition_IsEntityActive / IsEntityTrackingPlayer: an appeared
// entity of the unit, within `range` of `from` (0 = anywhere). "Tracking"
// additionally needs the entity to be rotating towards its target.
any_entity_of :: proc "contextless" (s: ^State, unit: Res_ID, from: Vec, range: i32, tracking: bool) -> bool {
	w := &s.world
	g := w.active.head
	for g != NO_LINK {
		i := w.groups[g].entities.head
		for i != NO_LINK {
			o := entity_at(s, i)
			if s.defs.units[o.unit].id == unit && o.appear_delay < 1 && (!tracking || o.rotating) {
				if range == 0 || distance_to(from, o.loc) <= f32(range) {
					return true
				}
			}
			i = w.entity_links[i].next
		}
		g = w.group_links[g].next
	}
	return false
}

// G_EG_RuleCondition_IsAnyDestroyable{Air,Ground}EntityActive: counted by
// the accuracy flags. Ground entities must also be within the game area.
any_destroyable :: proc(s: ^State, air: bool) -> bool {
	w := &s.world
	g := w.active.head
	for g != NO_LINK {
		i := w.groups[g].entities.head
		for i != NO_LINK {
			o := entity_at(s, i)
			u := &s.defs.units[o.unit]
			if air && u.include_in_air_accuracy_count {
				return true
			}
			if !air && u.include_in_ground_accuracy_count && within_game_area(s, o) {
				return true
			}
			i = w.entity_links[i].next
		}
		g = w.group_links[g].next
	}
	return false
}

// G_EG_RuleCondition_GetNumEntitiesActive_ByEntityType.
count_appeared :: proc "contextless" (s: ^State, unit: Res_ID) -> (n: i32) {
	if unit == NONE {
		return
	}
	w := &s.world
	g := w.active.head
	for g != NO_LINK {
		i := w.groups[g].entities.head
		for i != NO_LINK {
			o := entity_at(s, i)
			if s.defs.units[o.unit].id == unit && o.appear_delay < 1 {
				n += 1
			}
			i = w.entity_links[i].next
		}
		g = w.group_links[g].next
	}
	return
}

// Where an entity's owner is: the owning entity if it still exists, else the
// owning player if in play.
@(private = "file")
owner_loc :: proc "contextless" (s: ^State, e: ^Entity) -> (loc: Vec, ok: bool) {
	if ref_valid(s, e.owner) {
		return entity_at(s, e.owner.index).loc, true
	}
	if e.owner_player != -1 {
		p := &s.players[e.owner_player]
		if p.state == .Playing {
			return p.loc, true
		}
	}
	return {}, false
}

// FUN_0041bd90: sit at a fixed offset from the owner.
lock_to_owner :: proc "contextless" (s: ^State, e: ^Entity) {
	o, ok := owner_loc(s, e)
	if ok && (o.x != e.loc.x || o.y != e.loc.y) {
		e.loc = {o.x + e.owner_offset.x, o.y + e.owner_offset.y}
	}
}

// FUN_0041be80: move by however far the owner moved since last step.
link_to_owner :: proc "contextless" (s: ^State, e: ^Entity) {
	o, ok := owner_loc(s, e)
	if !ok {
		return
	}
	d := Vec{e.owner_loc.x - o.x, e.owner_loc.y - o.y}
	e.loc = {e.loc.x - d.x, e.loc.y - d.y}
	e.owner_loc = o
}

// FUN_0041bf70: circle the owner, the angle advancing by the (truncated)
// horizontal speed each step.
orbit_owner :: proc "contextless" (s: ^State, e: ^Entity) {
	o, ok := owner_loc(s, e)
	if !ok || (o.x == e.loc.x && o.y == e.loc.y) {
		return
	}
	next: Vec
	step := trunc_i32(e.vel.x)
	if e.orbit_radius == 0 || step == 0 {
		next = {o.x + e.owner_offset.x, o.y + e.owner_offset.y}
	} else {
		e.orbit_angle += step
		if e.orbit_angle >= 360 {
			e.orbit_angle -= 360
		} else if e.orbit_angle < 0 {
			e.orbit_angle += 360
		}
		p := vector_from_angle_and_speed(e.orbit_angle, e.orbit_radius)
		next = {o.x + p.x, o.y + p.y}
	}
	e.loc = next
	e.owner_offset = {e.loc.x - o.x, e.loc.y - o.y}
}

// G_Entity::Priv_DoCyclicMotion: wander, re-drawing a speed limit each step
// and reversing the acceleration whenever the velocity passes it.
cyclic_motion :: proc "contextless" (s: ^State, e: ^Entity) {
	st := state_of(s, e)
	top := trunc_i32(st.max_speed)
	whole := random_int(&s.rng, halve(top), top, 0x416032)
	frac := random_int(&s.rng, 1, 100, 0x41604f)
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
constrain_in_game_area :: proc "contextless" (s: ^State, e: ^Entity) {
	w, h := view_width(s.defs), view_height(s.defs)
	flip :: proc "contextless" (v: ^f32) {
		v^ = transmute(f32)(transmute(u32)v^ ~ 0x8000_0000)
	}
	bounce_x :: proc "contextless" (e: ^Entity) {
		flip(&e.vel.x)
		flip(&e.vel_delta.x)
		flip(&e.vel_target.x)
	}
	bounce_y :: proc "contextless" (e: ^Entity) {
		flip(&e.vel.y)
		flip(&e.vel_delta.y)
		flip(&e.vel_target.y)
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

// FUN_0041b090 / FUN_0041b1b0: when a spawner dies or is deleted, its
// children follow if their state allows it. The group totals are decremented
// here and again when the sweep reaches the child -- as in the original.
children_follow :: proc(s: ^State, parent: ^Entity, destroyed: bool) {
	w := &s.world
	n := w.active.count
	gc := Cursor{NO_LINK}
	for _ in 0 ..< n {
		gi := list_next(&w.active, w.group_links[:], &gc)
		m := w.groups[gi].entities.count
		ec := Cursor{NO_LINK}
		for _ in 0 ..< m {
			ci := list_next(&w.groups[gi].entities, w.entity_links[:], &ec)
			c := entity_at(s, ci)
			if c == parent || c.owner.number != parent.number {
				continue
			}
			st := state_of(s, c)
			if destroyed {
				if st.can_be_destroyed_on_owner_destruction {
					remove_from_group(s, gi, c, true, c.target_player != -1)
				}
			} else if st.can_be_deleted_on_owner_deletion {
				remove_from_group(s, gi, c, false, false)
			}
		}
	}
}

// G_Entity::Priv_HoldToTarget: close on the target at the state's hold speed.
hold_to_target :: proc "contextless" (s: ^State, e: ^Entity, target: Vec) {
	st := state_of(s, e)
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
reverse_from_target :: proc "contextless" (s: ^State, e: ^Entity, target: Vec, dist: f32) {
	d := target - e.loc
	if dist != 0 {
		d /= dist
	}
	top := state_of(s, e).max_speed
	e.vel_target = {-(d.x * top), -(d.y * top)}
}
