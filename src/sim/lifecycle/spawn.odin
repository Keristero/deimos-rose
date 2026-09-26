package lifecycle

// The entity lifecycle: making entities, changing their state, destroying
// them and freeing them. What Orion's entity builders are to its systems:
// every system that spawns, changes an entity's state or destroys one comes
// here, so the pool and its groups change in one place only.
//
// G_EntityGroup (G_EG_*): spawning groups of entities. Statics are named by
// what they do, with the original address.

import "dr:sim"
import "dr:sim/stats"
import "dr:sim/systems/debris_system"
import "dr:sim/systems/notice_system"

// G_EG_ResetAtLevelStart, with FUN_0041d110 (pool), FUN_0041a7c0 (old
// groups) and FUN_0041a5b0 (required groups from the level's placements).
eg_reset :: proc(s: ^sim.State, level: ^sim.Level_Def) {
	w := sim.single(s, sim.Pool)
	w.limit_warned = false
	w.used_count = 0
	w.free_hint = 0
	w.entity_used = {}
	w.group_used = {}
	for i in 0 ..< i32(sim.MAX_GROUPS) {
		sim.group_at(s, i)^ = {}
		sim.group_links(s)[i] = {}
	}
	w.active = sim.list_init()
	w.required = sim.list_init()
	w.next_entity = sim.FIRST_ENTITY_NUMBER
	w.next_group = sim.FIRST_GROUP_ID
	w.ground_targets = 0

	perm := sim.group_alloc(s)
	sim.list_append(&w.active, sim.group_links(s), perm)
	g := sim.group_at(s, perm)
	g.unit = sim.PERM_GROUP_UNIT
	g.id = w.next_group
	w.next_group += 1

	for p in level.placements {
		if p.unit == sim.NONE {
			continue
		}
		u := sim.unit_find(s.defs, p.unit)
		if u == nil {
			continue // "NOTE: An invalid Unit ID"
		}
		i := sim.group_alloc(s)
		sim.list_append(&w.required, sim.group_links(s), i)
		r := sim.group_at(s, i)
		r.unit = p.unit
		r.id = -1
		r.heading = p.heading
		r.stationary = p.stationary
		r.terrain_effects = p.terrain_effects
		r.loc = {f32(p.x), f32(p.y)}
		if u.is_ground_based {
			r.loc.x -= 32 // DAT_004e34b8
		}
	}
}

// G_EG_CheckForMapSpawnsAtRow: spawn every required group on this map row.
eg_spawn_map_row :: proc(s: ^sim.State, row: i32) {
	if row < 0 {
		return
	}
	w := sim.single(s, sim.Pool)
	n := w.required.count
	c := sim.Cursor{sim.NO_LINK}
	for _ in 0 ..< n {
		i := sim.list_next(&w.required, sim.group_links(s), &c)
		g := sim.group_at(s, i)
		if sim.trunc_i32(g.loc.y) != row {
			continue
		}
		req := sim.spawn_request(g.unit)
		req.loc = g.loc
		req.map_relative = true
		req.place_heading = g.heading
		req.stationary = g.stationary
		req.terrain_effects = g.terrain_effects
		sim.list_remove(&w.required, sim.group_links(s), i, &c)
		sim.group_free(s, i)
		eg_request_spawn(s, req)
	}
}

// FUN_0041b650: how many of a group to spawn.
group_size :: proc "contextless" (s: ^sim.State, u: ^sim.Unit) -> i32 {
	lo := max(u.num_in_group_min, 1)
	hi := u.num_in_group_max
	if hi < lo {
		lo = hi
	}
	n := lo
	if lo != hi {
		n = sim.roll_int(s, lo, hi, 0x41b68b)
	}
	count := n
	for _ in 0 ..< n {
		p := u.appears_percent
		if p == 100 {
			continue
		}
		if p != 0 && sim.roll_int(s, 0, 100, 0x41b6c6) <= p {
			continue
		}
		count -= 1
	}
	return count
}

// FUN_0041b740: live entities of a unit.
count_of_unit :: proc "contextless" (s: ^sim.State, id: sim.Res_ID) -> (n: i32) {
	walk := sim.walk_entities(s)
	for e in sim.walk_next(&walk) {
		if s.defs.units[e.unit].id == id {
			n += 1
		}
	}
	return
}

// Spawns `unit` at `loc` for player `owner_player` (-1 for none): the
// request most spawns make, the template's otherwise.
spawn_at :: proc(s: ^sim.State, unit: sim.Res_ID, loc: sim.Vec, owner_player: i32 = -1) -> sim.Entity_Ref {
	req := sim.spawn_request(unit)
	req.loc = loc
	req.owner_player = owner_player
	return eg_request_spawn(s, req)
}

// The middle of the visible play area, where the notices appear.
screen_centre :: proc "contextless" (s: ^sim.State) -> sim.Vec {
	return {s.defs.perm_floats[sim.PF_VISIBLE_GAME_WIDTH] / 2, s.defs.perm_floats[sim.PF_VISIBLE_GAME_HEIGHT] / 2}
}

// G_EG_RequestSpawn. Returns a reference to the first entity spawned.
eg_request_spawn :: proc(s: ^sim.State, req: sim.Spawn_Request) -> sim.Entity_Ref {
	w := sim.single(s, sim.Pool)
	time := sim.single(s, sim.Clock).time
	// Logged on entry, where the original's trace hook sits.
	sim.record_event(s, sim.Event{kind = .Spawn, unit = req.unit, loc = req.loc})
	ui := sim.unit_index(s.defs, req.unit)
	if ui < 0 {
		return sim.NO_REF // "ERROR: Couldn't get the Unit for ..."
	}
	u := &s.defs.units[ui]
	count := group_size(s, u)
	if count <= 0 {
		return sim.NO_REF
	}
	// DAT_004e34aa is on unless toggled from the debug console.
	if u.can_be_spawned_only_when_players_active && !(sim.players_in_play(s) > 0 && !sim.single(s, sim.Level_Info).ending) {
		return sim.NO_REF
	}
	if u.do_not_spawn_if_type_already_exists && count_of_unit(s, req.unit) != 0 {
		return sim.NO_REF
	}
	if w.used_count + count >= 1001 {
		w.limit_warned = true // "Reached Entity Limit"
		return sim.NO_REF
	}
	// FUN_0041b820: this player's existing entities of the same unit make way.
	if u.delete_existing_entities_of_this_type_owned_by_player && req.owner_player != -1 {
		walk := sim.cursor_walk(s, fixed = true)
		for o in sim.cursor_next(&walk) {
			if s.defs.units[o.unit].id == req.unit && o.owner_player == req.owner_player {
				remove_from_group(s, walk.group, o, false, false)
			}
		}
	}

	// A single entity with no owner outside the PERM group joins PERM.
	gi: i32
	alone := count == 1
	if alone && req.owner.index != sim.NO_LINK {
		alone = sim.entity_at(s, req.owner.index).group == sim.FIRST_GROUP_ID
	}
	if alone {
		gi = w.active.head // the first active group
		g := sim.group_at(s, gi)
		g.count = count
		g.total += count
	} else {
		gi = sim.group_alloc(s)
		sim.list_append(&w.active, sim.group_links(s), gi)
		g := sim.group_at(s, gi)
		g.unit = req.unit
		g.count = count
		g.total = count
		g.killed = 0
		g.heading = req.place_heading
		g.stationary = req.stationary
		g.terrain_effects = req.terrain_effects
		g.id = w.next_group
		w.next_group += 1
	}
	g := sim.group_at(s, gi)
	g.loc.x = req.loc.x
	if !req.map_relative {
		g.loc.y = req.loc.y
	} else {
		g.loc.y = f32(-(sim.single(s, sim.Bgnd).view_top - sim.trunc_i32(req.loc.y)))
	}
	heading: i32
	use_heading: bool
	if !req.explicit_heading {
		heading = req.place_heading
		use_heading = u.initial_heading_set_in_editor
	} else {
		heading = req.heading
		use_heading = true
	}

	// FUN_0041a890: spawn the group's members; only the first gets `out`.
	first := sim.NO_REF
	delay: i32
	for i in 0 ..< g.count {
		r := spawn_entity(s, gi, i32(ui), req, time, &delay, use_heading, heading)
		if i == 0 {
			first = r
		}
		if g.count == 1 {
			break
		}
	}

	if u.entry_notice != "" {
		notice_system.notice_request(s, u, time)
	}
	return first
}

// FUN_0041d1d0: take a pool slot. The hint is the last slot freed.
//
// A slot keeps its components for the session, as the original's pool keeps
// its preallocated objects, so a stale Entity_Ref still reads what the
// slot's last entity left.
entity_alloc :: proc(s: ^sim.State) -> i32 {
	w := sim.single(s, sim.Pool)
	if w.used_count >= sim.MAX_ENTITIES {
		return sim.NO_LINK // "DEBUG: Reached the end of preallocated entities"
	}
	i := w.free_hint
	if i == -1 {
		for used, j in w.entity_used {
			if !used {
				i = i32(j)
				break
			}
		}
	}
	if i == -1 {
		return sim.NO_LINK
	}
	w.used_count += 1
	w.entity_used[i] = true
	entity_reset(sim.entity_at(s, i), i)
	w.free_hint = -1
	return i
}

// FUN_0041d2b0: release a pool slot; it becomes the next one handed out.
entity_free :: proc "contextless" (s: ^sim.State, i: i32) {
	w := sim.single(s, sim.Pool)
	w.free_hint = i
	w.entity_used[i] = false
	w.used_count -= 1
}

// FUN_0041a990: create and initialise one entity of a group.
spawn_entity :: proc(
	s: ^sim.State,
	gi: i32,
	ui: i32,
	req: sim.Spawn_Request,
	time: i32,
	delay: ^i32,
	use_heading: bool,
	heading: i32,
) -> sim.Entity_Ref {
	w := sim.single(s, sim.Pool)
	ei := entity_alloc(s)
	if ei == sim.NO_LINK {
		return sim.NO_REF
	}
	g := sim.group_at(s, gi)
	sim.list_append(&g.entities, sim.entity_links(s), ei)
	e := sim.entity_at(s, ei)
	u := &s.defs.units[ui]

	// G_Entity::SetUnitRef.
	e.unit = ui
	if u.draw_layer == sim.res_id("hud ") {
		e.scrolls_sideways = false
	}
	for &st in u.states {
		if len(st.spawn_sets) > 0 {
			e.has_spawn_info = true
		}
	}

	e.owner = req.owner
	e.draw_layer = u.draw_layer
	e.state = -1
	e.number = w.next_entity
	w.next_entity += 1
	e.group = g.id
	e.deleted = false
	e.owner_player = req.owner_player
	e.target_player = -1
	e.anim_time = time
	e.anim_backwards = false
	e.killed_by_player = false
	for &st in u.states {
		if st.use_this_state_on_shield_depletion {
			e.has_depletion_state = true
			break
		}
	}
	vis := f64(u.initial_visibility_percent)
	e.hittable = vis == 100 || (vis < 100 && u.hittable_when_invisible)
	e.vel_delta = {}
	e.shields = u.shields_base_amount
	if u.shields_level_increment > 0 {
		e.shields = f32(sim.single(s, sim.Level_Info).number - 1) * u.shields_level_increment + e.shields
		if u.shields_max_amount < e.shields {
			e.shields = u.shields_max_amount
		}
	}

	h := heading
	if !use_heading {
		h = u.initial_heading
	} else if tol := u.initial_heading_tolerance; tol != 0 {
		half := halve(tol)
		h = heading + sim.roll_int(s, -half, half, 0x41aba1)
		if h < 0 {
			h += 360
		} else if h > 359 {
			h -= 360
		}
		if h < 0 || h > 359 {
			h = 0
		}
	}
	e.heading = h
	e.stationary = req.stationary
	e.terrain_effects = req.terrain_effects
	e.shaped_by = req.shaped_by
	e.shaped_depth = req.shaped_depth

	spawn_location(s, g, e)
	spawn_velocity(s, g, e, use_heading, h, req.owner, req.speed_scale)
	del, des := change_state(s, e, true, u.states[0].name, time)
	if del || des {
		// A first state of Delete or Destroy: not ported, and no shipped
		// unit has one. The entity is left in its first state, so everything
		// that reads its state still can, and deleted at once.
		sim.unported(s, 0x41ab1c)
		e.state = 0
		entity_delete(e)
	}
	st := sim.state_of(s, e)
	e.is_air = !u.is_ground_based
	e.shadow_scaled = u.adjust_shadow_loc_for_scaling
	cache_owner_offsets(s, e)

	if u.group_delay_min == u.group_delay_max {
		delay^ += u.group_delay_min
	} else {
		delay^ += sim.roll_int(s, u.group_delay_min, u.group_delay_max, 0x41acc6)
	}
	e.appear_delay = delay^

	if st.cyclic_motion {
		cyclic_velocity(s, e)
	}
	if e.stationary && u.destruct_create_obstacle {
		debris_system.debris_new(s, object_bounds(e.obj))
	}
	if st.use_parent_direction && sim.ref_valid(s, e.owner) {
		// Face the way the owner faces.
		o := sim.entity_at(s, e.owner.index)
		if o.state >= 0 {
			f := frame_for_angle(s, e, angle_from_sprite(s, o))
			spr := sim.sprite_find(s.defs, e.sprite)
			n := spr == nil ? 0 : i32(len(spr.frames))
			e.frame = f < 0 || f >= n ? 0 : f
			e.has_frame_ptr = true
		}
	}
	if u.include_in_ground_accuracy_count {
		sim.single(s, sim.Accuracy).targets += 1 // G_Game_GroundAccuracy_AddTarget
		w.ground_targets += 1
	}
	if e.shaped_by != 0 {
		stats.shaped_entity_init(s, e, time)
	}
	return {ei, e.number}
}

// FUN_0041c540: where in (or around) its group an entity appears.
spawn_location :: proc "contextless" (s: ^sim.State, g: ^sim.Group, e: sim.Entity) {
	u := sim.unit_of(s, e)
	xmin, xmax := u.x_offset_min, u.x_offset_max
	ymin, ymax := u.y_offset_min, u.y_offset_max
	loc: sim.Vec
	if xmin == xmax || ymin == ymax {
		if xmin == xmax {
			loc.x = g.loc.x + xmin
		} else {
			lo, hi := xmin, xmax
			if xmax < xmin {
				lo, hi = xmax, xmin
			}
			loc.x = f32(sim.roll_int(s, sim.trunc_i32(lo), sim.trunc_i32(hi), 0x41c718)) + g.loc.x
		}
		if ymin == ymax {
			loc.y = g.loc.y + ymin
		} else {
			lo, hi := ymin, ymax
			if ymax < ymin {
				lo, hi = ymax, ymin
			}
			loc.y = f32(sim.roll_int(s, sim.trunc_i32(lo), sim.trunc_i32(hi), 0x41c7e8)) + g.loc.y
		}
	} else {
		// Both ranges open: a point on (or within) an ellipse.
		v := sim.vector_from_angle(sim.roll_int(s, 0, 359, 0x41c5c1))
		if !u.randomise_initial_loc {
			loc = {v.x * abs(xmax) + g.loc.x, v.y * abs(ymax) + g.loc.y}
		} else {
			r := sim.roll_float(s, 0, abs(xmax), 0x41c5ff)
			loc = {v.x * r + g.loc.x, v.y * r + g.loc.y}
		}
	}
	e.loc = loc
}

// FUN_0041c840: initial velocity.
spawn_velocity :: proc "contextless" (
	s: ^sim.State,
	g: ^sim.Group,
	e: sim.Entity,
	use_heading: bool,
	heading: i32,
	owner: sim.Entity_Ref,
	speed_scale: f32,
) {
	if e.stationary {
		e.vel, e.vel_target, e.vel_delta = {}, {}, {}
		return
	}
	u := sim.unit_of(s, e)
	speed := sim.roll_float(s, u.initial_speed_min, u.initial_speed_max, 0x41c8c4)
	angle: i32
	if use_heading || u.initial_heading_set_in_editor {
		angle = sim.invert_angle(heading)
	} else if u.initially_hunts_closest_player {
		sim.unported(s, 0x41c8f0)
		return
	} else if u.do_burst || u.do_implode {
		sim.unported(s, 0x41c9a0)
		return
	} else {
		a: i32
		ok := false
		if !u.use_owner_heading || owner.index == sim.NO_LINK {
			a = u.initial_heading
			ok = true
		} else {
			sim.unported(s, 0x41ca5c) // G_Entity::GetAngleFromSpriteInfo(owner)
			return
		}
		if ok && u.initial_heading_tolerance != 0 {
			half := halve(u.initial_heading_tolerance)
			a += sim.roll_int(s, -half, half, 0x41caaa)
			if a < 0 {
				a += 360
			} else if a > 359 {
				a -= 360
			}
			if a < 0 || a > 359 {
				a = 0
			}
		}
		e.heading = a
		angle = sim.invert_angle(a)
	}
	e.vel = sim.vector_from_angle_and_speed(angle, speed)
	if speed_scale != 1 {
		e.vel *= speed_scale
	}
	e.vel_prev = e.vel
	e.vel_target = e.vel
	e.vel_delta = {}
}

// FUN_0041cbc0: the random drift of a cyclic-motion state.
cyclic_velocity :: proc "contextless" (s: ^sim.State, e: sim.Entity) {
	speed: f32 = sim.roll_int(s, 0, 1, 0x41cbe1) == 0 ? 1.4 : 1.0
	whole := sim.roll_int(s, 1, 4, 0x41cc0f)
	frac := f32(sim.roll_int(s, 1, 100, 0x41cc2c)) / 100
	x := f32(whole) + frac
	if sim.roll_int(s, 0, 1, 0x41cc58) != 0 {
		x = -x
	}
	y := f32(sim.roll_int(s, 1, 4, 0x41cc7d)) + frac
	quarter := f32(sim.view_height(s.defs) / 4)
	if quarter < e.loc.y {
		if sim.roll_int(s, 0, 1, 0x41cd11) != 0 {
			y = -y
		}
	}
	len := sim.m_sqrt(sim.trunc_i32(x * x + y * y))
	e.vel = {x / len * speed, y / len * speed}
	e.vel_target = e.vel
	e.vel_prev = e.vel
	e.vel_delta = {x / len * f32(0.2), y / len * f32(0.2)}
}
