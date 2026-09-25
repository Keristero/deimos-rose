package sim

// G_Entity: one spawned unit.
//
// Each proc names the original function it reproduces. Random calls pass the
// original call site (the RandomInt/RandomFloat return address) so the oracle
// diff can name the first divergence precisely.

unit_of :: #force_inline proc "contextless" (s: ^State, e: Entity) -> ^Unit {
	return &s.defs.units[e.unit]
}

state_of :: #force_inline proc "contextless" (s: ^State, e: Entity) -> ^Unit_State {
	return &s.defs.units[e.unit].states[e.state]
}

// U_Sprite_GetDimensions / ..ForSpriteFrameData: frame size, scaled with C
// truncation unless the scale is exactly 1.
sprite_dims :: proc "contextless" (s: ^State, sprite: Res_ID, frame: i32, scale: f32) -> [2]i32 {
	if sprite == NONE {
		return {}
	}
	spr := sprite_find(s.defs, sprite)
	if spr == nil || frame < 0 || int(frame) >= len(spr.frames) {
		// The original asserts (after trying to load the group). Never
		// happens with shipped data: every state's frame range fits.
		return {}
	}
	f := spr.frames[frame]
	if scale == 1 {
		return {f.width, f.height}
	}
	return {trunc_i32(f32(f.width) * scale), trunc_i32(f32(f.height) * scale)}
}

// G_GameObject::CalculateDimensions.
calculate_dimensions :: proc "contextless" (s: ^State, o: ^Game_Object) {
	if !o.dims_dirty {
		return
	}
	if o.sprite == NONE {
		o.half = {}
	} else {
		o.dims = sprite_dims(s, o.sprite, o.frame, o.scale)
		// (n + 1 - (n < 0x80000000)) >> 1: halving that rounds toward zero.
		o.half = {o.dims.x / 2, o.dims.y / 2}
	}
	o.dims_dirty = false
}

// G_GameObject::GetBounds, as U_Rect (top, left, bottom, right).
object_bounds :: proc "contextless" (o: ^Game_Object) -> Rect {
	return {
		top    = trunc_i32(o.loc.y - f32(o.half.y)),
		left   = trunc_i32(o.loc.x - f32(o.half.x)),
		bottom = trunc_i32(f32(o.half.y) + o.loc.y),
		right  = trunc_i32(f32(o.half.x) + o.loc.x),
	}
}

// G_GameObject::DoScaling.
do_scaling :: proc "contextless" (o: ^Game_Object) {
	if o.scale > o.scale_target {
		o.dims_dirty = true
		o.scale -= o.scale_delta
		if o.scale < o.scale_target {
			o.scale = o.scale_target
		}
	} else if o.scale < o.scale_target {
		o.dims_dirty = true
		o.scale += o.scale_delta
		if o.scale_target < o.scale {
			o.scale = o.scale_target
		}
	}
}

// G_GameObject::AdjustVisibilityAndTinting.
adjust_visibility_and_tinting :: proc "contextless" (o: ^Game_Object) {
	step :: proc "contextless" (v: ^f32, target, delta: f32) {
		if v^ > target {
			v^ -= delta
			if v^ < 0 {
				v^ = 0
			}
			if v^ < target {
				v^ = target
			}
		} else if v^ < target {
			v^ += delta
			if target < v^ {
				v^ = target
			}
		}
	}
	step(&o.visibility, o.visibility_target, o.visibility_delta)
	step(&o.tint, o.tint_target, o.tint_delta)
}

// G_Entity::Reset: a pool slot made ready for a new entity. Its Link is the
// list's to set.
entity_reset :: proc "contextless" (e: Entity, pool_index: i32) {
	e.actor^ = Actor {
		unit           = NO_LINK,
		number         = -1,
		group          = -1,
		state          = -1,
		owner_player   = -1,
		target_player  = -1,
		powerup_weapon = NONE,
		pool_index     = pool_index,
	}
	e.anim^ = {}
	e.motion^ = Motion{hunt_player = -1}
	e.owned^ = Owned{owner = NO_REF}
	e.spawner^ = {}
	e.effects^ = {}
	e.tag^ = {}
	object_defaults(e.obj)
}

// G_Entity::GetFrameForAngle.
frame_for_angle :: proc "contextless" (s: ^State, e: Entity, angle: i32) -> i32 {
	st := state_of(s, e)
	dirs := max(st.num_directions, 1)
	f := f32(angle) / f32(360 / dirs)
	i := trunc_i32(f)
	if f - f32(i) >= 0.5 {
		i += 1
	}
	if i < 0 {
		i = dirs - 1
	} else if i > dirs - 1 {
		i = 0
	}
	return i * st.frames_per_direction
}

// G_Entity::Priv_CheckSpawningAbilityAtStateChange.
reset_spawn_info :: proc "contextless" (s: ^State, e: Entity, time: i32) {
	st := state_of(s, e)
	n := len(st.spawn_sets)
	e.spawning = n > 0
	for &set, i in st.spawn_sets {
		info := &e.spawn_info[i]
		if set.spawn == NONE {
			info.last = time
			info.delay = 0
			info.active = false
			e.spawn_pause = 0
			continue
		}
		info.delay = roll_int(s, set.rate_min, set.rate_max, 0x416e24)
		info.last = time
		info.volley = roll_int(s, set.num_in_volley_min, set.num_in_volley_max, 0x416e3e)
		info.active = info.delay >= 0 && info.volley > 0
		info.left = info.volley
		info.gap = roll_int(s, set.delay_between_entities_min, set.delay_between_entities_max, 0x416e71)
		e.spawn_pause = set.time_to_pause_rotation_after_spawning
	}
}

// G_Entity::ChangeState. Returns whether the entity is to be deleted or
// destroyed (the original's two out-parameters).
change_state :: proc(s: ^State, e: Entity, init: bool, name: string, time: i32) -> (delete, destroy: bool) {
	if name == "Delete" {
		return true, false
	}
	if name == "Destroy" {
		return false, true
	}
	u := unit_of(s, e)
	// Logged before the lookup, where the original's trace hook sits: a name
	// that matches no state is still an attempt (and does nothing).
	record_event(s, Event{kind = .State, unit = u.id, number = e.number, state = name, loc = e.loc})
	next, found := state_find(u, name)
	if !found {
		return
	}

	// Properties of the state being left. On an entity's very first state
	// change there is none: the original then reads the unit definition at a
	// negative state offset (def - 0x5da + 0x804, + 0x7f4), bytes 0x21a..0x22d
	// that no loader writes. They are zero: FUN_00442140 clears the whole
	// 0x79e0-byte definition before G_UnitDef_SetToDefaults, which does not
	// touch them.
	keep_angle := false
	keep_angle_value: i32
	prev_flee := Res_ID{}
	if e.state >= 0 {
		prev := state_of(s, e)
		if prev.orbit_owner {
			keep_angle = true
			keep_angle_value = e.orbit_angle
		}
		prev_flee = prev.flee
	}
	old_sprite, old_frame := e.sprite, e.frame

	e.state = i32(next)
	e.state_time = time
	e.entry_counts[e.state] += 1
	e.collision_time = time
	e.collision_count = 0
	e.sound_count = 0
	e.particle_count = 0
	e.anim_done = false
	st := state_of(s, e)
	e.timer = roll_int(s, st.on_timer_min, st.on_timer_max, 0x41374b)

	// Pickups show the weapon they carry instead of the state's sprite.
	powerup := Res_ID{}
	switch u.pickup_type {
	case res_id("air "):
		powerup = res_id("PEAA")
	case res_id("spec"):
		powerup = res_id("SPEC")
	case res_id("grnd"):
		powerup = res_id("PEAG")
	}
	if powerup != (Res_ID{}) {
		unported(s, 0x41377e) // weapon pickup appearance
	} else {
		e.sprite = st.sprite_face
		if init || e.sprite != old_sprite {
			if !u.initial_heading_set_in_editor {
				e.frame = roll_int(s, st.sprite_frame_min, st.sprite_frame_max, 0x41382d)
			} else {
				e.frame = frame_for_angle(s, e, e.heading)
			}
		}
		e.has_frame_ptr = true
	}
	e.draw_to_terrain = st.draw_to_terrain

	if init {
		e.visibility = f32(u.initial_visibility_percent)
		e.visibility_target = f32(st.required_visibility_percent)
		e.visibility_delta = f32(st.visibility_delta_percent)
		e.tint = f32(st.tint_percent)
		e.tint_target = f32(st.tint_percent)
		e.tint_delta = f32(st.tint_delta_percent)
		e.tint_color = color_1555(st.tint_color)
		scale := u.initial_scale_percent
		if tol := u.initial_scale_percent_tolerance; tol != 0 {
			half := halve(tol)
			scale += roll_int(s, -half, half, 0x4138f4)
			if scale < 0 {
				scale = 0
			}
		}
		e.scale = f32(scale) / 100
		e.scale_target = f32(st.required_scale_percent) / 100
		e.scale_delta = f32(st.scale_delta_percent) / 100
	}
	// CalculateDimensions only recomputes when the dirty flag is already set,
	// and nothing here sets it: after an entity's first state, a new sprite
	// keeps the old dimensions until animation or scaling marks them dirty.
	// Faithful to the original.
	if init || e.sprite != old_sprite || e.frame != old_frame {
		calculate_dimensions(s, e.obj)
	}
	e.anim_backwards = st.do_animate_backwards

	if init {
		if !st.lock_to_owner_loc {
			approach(e, invert_angle(e.heading), st.max_speed, st.delta)
		} else {
			e.vel, e.vel_delta, e.vel_target = {}, {}, {}
		}
	} else if !st.lock_to_owner_loc {
		angle := keep_angle ? keep_angle_value : angle_from_vector(e.vel)
		approach(e, angle, st.max_speed, st.delta)
		if e.group != -1 {
			cache_owner_offsets(s, e)
		}
	} else {
		e.vel, e.vel_delta, e.vel_target = {}, {}, {}
	}

	if st.flee == NONE {
		if e.fleeing && prev_flee != NONE {
			e.fleeing = false
		}
	} else {
		entity_flee(s, e, st.flee)
	}

	reset_spawn_info(s, e, time)

	if st.on_counter > 0 && e.entry_counts[e.state] == st.on_counter {
		to := st.on_counter_change_to
		if to == "Delete" {
			return true, false
		}
		if to == "Destroy" {
			return false, true
		}
		if to != "" && to != "none" {
			e.entry_counts[e.state] = 0
			del, des := change_state(s, e, false, to, time)
			if del || des {
				return del, des
			}
		}
	}

	// Uses the state entered above (st), not any state entered by the
	// counter recursion -- as the original does.
	e.animating = e.sprite != NONE && st.frame_delta > 0
	return
}

// C's (n + 1 - (n < 0x80000000)) >> 1 on an unsigned n: n / 2 rounded up for
// the non-negative values it is used on.
halve :: #force_inline proc "contextless" (n: i32) -> i32 {
	return i32((u32(n) + 1 - (u32(n) < 0x8000_0000 ? 1 : 0)) >> 1)
}

// The velocity approach shared by both branches of ChangeState: head for
// `max_speed` along `angle`, changing speed by at most `delta` per step.
@(private = "file")
approach :: proc "contextless" (e: Entity, angle: i32, max_speed, delta: f32) {
	speed := speed_from_vector(e.vel)
	d := speed < max_speed ? max_speed - speed : speed - max_speed
	step := delta
	if d < delta {
		step = d
	}
	target := max_speed <= speed ? speed - step : speed + step
	v := vector_from_angle_and_speed(angle, target)
	e.vel_delta = v - e.vel
	e.vel_target = vector_from_angle_and_speed(angle, max_speed)
}

// G_EG_CacheOwnerLocOffsetsAndAngles: for states that follow their owner,
// remember where the owner is and how far away (lock / link: the offset;
// orbit: the offset, radius and angle).
cache_owner_offsets :: proc(s: ^State, e: Entity) {
	e.owner_offset = {}
	e.owner_loc = {}
	st := state_of(s, e)
	if !(st.orbit_owner || st.lock_to_owner_loc || st.link_to_owner_loc) {
		return
	}
	owner: Vec
	found := false
	if ref_valid(s, e.owner) {
		owner = entity_at(s, e.owner.index).loc
		found = true
	} else if e.owner_player != -1 {
		p := player_at(s, e.owner_player)
		if p.state == .Playing {
			owner, found = p.loc, true
		}
	}
	if !found {
		return
	}
	e.owner_loc = owner
	me := e.loc
	// The original spells a - b as either (a - b) or -(b - a) depending on
	// the sign; both are the same value.
	if st.orbit_owner {
		e.owner_offset = {owner.x < me.x ? me.x - owner.x : -(owner.x - me.x), owner.y < me.y ? me.y - owner.y : -(owner.y - me.y)}
		e.orbit_radius = f32(trunc_i32(distance_to(owner, me)))
		e.orbit_angle = invert_angle(intercept_angle(trunc_i32(owner.x), trunc_i32(owner.y), trunc_i32(me.x), trunc_i32(me.y)))
	}
	if st.lock_to_owner_loc {
		e.owner_offset = {owner.x < me.x ? me.x - owner.x : -(owner.x - me.x), owner.y < me.y ? me.y - owner.y : -(owner.y - me.y)}
	}
}

// G_Entity::Animate.
entity_animate :: proc(s: ^State, e: Entity, time: i32) {
	if !e.animating {
		return
	}
	st := state_of(s, e)
	delta := st.frame_delta
	if !(delta > 0 && !st.do_rotate_to_target && e.anim_time + st.frame_delay < time) {
		return
	}
	dir := trunc_i32(f32(st.num_directions) * (f32(e.heading) / 360))
	first := dir * st.frames_per_direction
	past := first + st.frames_per_direction
	last := past - 1
	if !st.continuous_frame_randomisation {
		for i: i32 = 0; i < delta && !e.anim_done; i += 1 {
			if !e.anim_backwards {
				if e.frame == last {
					if !st.do_loop_animation {
						e.anim_done = true
					} else if !st.do_animate_backwards {
						e.frame = first
					} else {
						e.anim_backwards = true
						e.frame = past - 2
					}
				} else {
					e.frame += 1
				}
			} else if e.frame == first {
				if !st.do_loop_animation {
					e.anim_done = true
				} else if !st.do_animate_backwards {
					e.frame = last
				} else {
					e.anim_backwards = false
					e.frame = first + 1
				}
			} else {
				e.frame -= 1
			}
		}
	} else {
		e.frame = roll_int(s, first, last, 0x4149db)
	}
	e.anim_time = time
	e.dims_dirty = true
	e.has_frame_ptr = true
}

// G_Entity::Priv_Flee: head off the map in the named direction. The target
// point goes in the hunt target, which Priv_MoveToTargetLoc then steers to at
// the state's flee speed.
//
// Only the ids the shipped data uses are ported: nora, sora, cega, noce and
// soce (1,150 states name "none"). The rest mark themselves unported rather
// than guess which of Priv_Flee's twelve call sites belongs to which branch.
//
// The two sites seen in the traces both draw RandomFloat(0, 416) -- the x
// coordinate for nora and sora -- so the RNG stream is the same either way,
// but the site identifies the branch: de04 step 2065 shows a "sora" flee
// drawing at 0x416630, so 0x4165f0 is nora.
entity_flee :: proc(s: ^State, e: Entity, flee: Res_ID) {
	e.fleeing = true
	d := s.defs
	w := d.perm_floats[PF_VISIBLE_GAME_WIDTH]
	h := d.perm_floats[PF_VISIBLE_GAME_HEIGHT]
	north := d.perm_floats[0xe] // Game_EntityFleeNorthLocation
	south := d.perm_floats[0xf]
	switch flee {
	case res_id("cega"): // centre
		e.hunt_target = {w / 2, h / 2}
	case res_id("nora"): // north, random x
		e.hunt_target = {roll_float(s, 0, w, 0x4165f0), north}
	case res_id("sora"): // south, random x
		e.hunt_target = {roll_float(s, 0, w, 0x416630), south}
	case res_id("noce"): // north, centred
		e.hunt_target = {w / 2, north}
	case res_id("soce"): // south, centred
		e.hunt_target = {w / 2, south}
	case NONE:
	case:
		unported(s, 0x416520) // east/west/random/opposite flees
	}
}

// G_GameObject::Glow_Start. `restart` re-triggers a glow already running.
glow_start :: proc "contextless" (o: ^Game_Object, color: u16, speed: i32, restart: bool) {
	if o.glowing && !restart {
		return
	}
	o.glowing = true
	o.glow_falling = true
	o.glow_amount = 32
	o.glow_speed = speed
	o.glow_color = color
}

// G_GameObject::Glow_Stop.
glow_stop :: proc "contextless" (o: ^Game_Object) {
	o.glowing = false
	o.glow_falling = false
	o.glow_amount = 0
}

// G_GameObject::Glow_Process: the blend falls from 32 to 4 and back, and the
// glow ends when it reaches 32 again.
glow_process :: proc "contextless" (o: ^Game_Object) {
	if !o.glowing {
		return
	}
	if o.glow_falling {
		o.glow_amount -= o.glow_speed
		if o.glow_amount < 4 {
			o.glow_amount = 4
			o.glow_falling = false
		}
	} else {
		o.glow_amount += o.glow_speed
		if o.glow_amount > 32 {
			o.glow_amount = 32
			o.glow_falling = true
			o.glowing = false
		}
	}
}
