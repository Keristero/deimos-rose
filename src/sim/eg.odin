package sim

// G_EntityGroup (G_EG_*): spawning groups of entities and processing them
// every step. Statics are named by what they do, with the original address.

// G_EG_SpawnRequest. Every caller copies a static template (identical in
// G_EG, G_Game and G_Player: id "none", owner player -1, speed 1.0) and fills
// in what it needs.
Spawn_Request :: struct {
	unit:          Res_ID, // +0x00
	loc:           Vec,    // +0x04
	map_relative:  bool,   // +0x0c y is a map row; converted to screen space
	explicit_heading: bool, // +0x0d
	heading:       i32,    // +0x0e used when explicit_heading
	owner_player:  i32,    // +0x12
	place_heading: i32,    // +0x16 the placement's heading
	stationary:    bool,   // +0x1a
	terrain_effects: bool, // +0x1b
	owner:         Entity_Ref, // +0x1c
	speed_scale:   f32,    // +0x24
}

spawn_request :: proc "contextless" (unit: Res_ID) -> Spawn_Request {
	return {unit = unit, owner_player = -1, owner = NO_REF, speed_scale = 1}
}

entity_at :: #force_inline proc "contextless" (s: ^State, i: i32) -> ^Entity {
	return &s.world.entities[i]
}

// FUN_0041b700: is a reference still the entity it was taken from?
ref_valid :: proc "contextless" (s: ^State, r: Entity_Ref) -> bool {
	if r.index == NO_LINK {
		return false
	}
	e := entity_at(s, r.index)
	return r.number == e.number && !e.deleted
}

// G_EG_ResetAtLevelStart, with FUN_0041d110 (pool), FUN_0041a7c0 (old
// groups) and FUN_0041a5b0 (required groups from the level's placements).
eg_reset :: proc "contextless" (s: ^State, level: ^Level_Def) {
	w := &s.world
	w.limit_warned = false
	w.used_count = 0
	w.free_hint = 0
	w.entity_used = {}
	w.groups = {}
	w.group_links = {}
	w.active = list_init()
	w.required = list_init()
	w.next_entity = FIRST_ENTITY_NUMBER
	w.next_group = FIRST_GROUP_ID
	w.ground_targets = 0

	perm := group_alloc(w)
	list_append(&w.active, w.group_links[:], perm)
	g := &w.groups[perm]
	g.unit = PERM_GROUP_UNIT
	g.id = w.next_group
	w.next_group += 1

	for p in level.placements {
		if p.unit == NONE {
			continue
		}
		u := unit_find(s.defs, p.unit)
		if u == nil {
			continue // "NOTE: An invalid Unit ID"
		}
		i := group_alloc(w)
		list_append(&w.required, w.group_links[:], i)
		r := &w.groups[i]
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
eg_spawn_map_row :: proc(s: ^State, row: i32) {
	if row < 0 {
		return
	}
	w := &s.world
	n := w.required.count
	c := Cursor{NO_LINK}
	for _ in 0 ..< n {
		i := list_next(&w.required, w.group_links[:], &c)
		g := w.groups[i]
		if trunc_i32(g.loc.y) != row {
			continue
		}
		req := spawn_request(g.unit)
		req.loc = g.loc
		req.map_relative = true
		req.place_heading = g.heading
		req.stationary = g.stationary
		req.terrain_effects = g.terrain_effects
		list_remove(&w.required, w.group_links[:], i, &c)
		group_free(w, i)
		eg_request_spawn(s, req)
	}
}

// FUN_0041b650: how many of a group to spawn.
group_size :: proc "contextless" (s: ^State, u: ^Unit) -> i32 {
	lo := max(u.num_in_group_min, 1)
	hi := u.num_in_group_max
	if hi < lo {
		lo = hi
	}
	n := lo
	if lo != hi {
		n = random_int(&s.rng, lo, hi, 0x41b68b)
	}
	count := n
	for _ in 0 ..< n {
		p := u.appears_percent
		if p == 100 {
			continue
		}
		if p != 0 && random_int(&s.rng, 0, 100, 0x41b6c6) <= p {
			continue
		}
		count -= 1
	}
	return count
}

// FUN_0041b740: live entities of a unit.
count_of_unit :: proc "contextless" (s: ^State, id: Res_ID) -> (n: i32) {
	w := &s.world
	g := w.active.head
	for g != NO_LINK {
		e := w.groups[g].entities.head
		for e != NO_LINK {
			if s.defs.units[entity_at(s, e).unit].id == id {
				n += 1
			}
			e = w.entity_links[e].next
		}
		g = w.group_links[g].next
	}
	return
}

// G_EG_RequestSpawn. Returns a reference to the first entity spawned.
eg_request_spawn :: proc(s: ^State, req: Spawn_Request) -> Entity_Ref {
	w := &s.world
	time := s.time
	ui := unit_index(s.defs, req.unit)
	if ui < 0 {
		return NO_REF // "ERROR: Couldn't get the Unit for ..."
	}
	u := &s.defs.units[ui]
	count := group_size(s, u)
	if count <= 0 {
		return NO_REF
	}
	if u.can_be_spawned_only_when_players_active {
		unported(s, 0x417b3d) // needs G_Game_Player_IsAnyActive / waiting-for-level-end
		return NO_REF
	}
	if u.do_not_spawn_if_type_already_exists && count_of_unit(s, req.unit) != 0 {
		return NO_REF
	}
	if w.used_count + count >= 1001 {
		w.limit_warned = true // "Reached Entity Limit"
		return NO_REF
	}
	if u.delete_existing_entities_of_this_type_owned_by_player && req.owner_player != -1 {
		unported(s, 0x417bf3) // FUN_0041b820
	}

	// A single entity with no owner outside the PERM group joins PERM.
	gi: i32
	single := count == 1
	if single && req.owner.index != NO_LINK {
		single = entity_at(s, req.owner.index).group == FIRST_GROUP_ID
	}
	if single {
		gi = list_nth(&w.active, w.group_links[:], 0)
		g := &w.groups[gi]
		g.count = count
		g.total += count
	} else {
		gi = group_alloc(w)
		list_append(&w.active, w.group_links[:], gi)
		g := &w.groups[gi]
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
	g := &w.groups[gi]
	g.loc.x = req.loc.x
	if !req.map_relative {
		g.loc.y = req.loc.y
	} else {
		g.loc.y = f32(-(s.bgnd.view_top - trunc_i32(req.loc.y)))
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
	first := NO_REF
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
		notice_request(s, u, time)
	}
	return first
}

unit_index :: proc "contextless" (d: ^Defs, id: Res_ID) -> i32 {
	for &u, i in d.units {
		if u.id == id {
			return i32(i)
		}
	}
	return -1
}

// FUN_0041d1d0: take a pool slot. The hint is the last slot freed.
entity_alloc :: proc "contextless" (w: ^World) -> i32 {
	if w.used_count >= MAX_ENTITIES {
		return NO_LINK // "DEBUG: Reached the end of preallocated entities"
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
		return NO_LINK
	}
	w.used_count += 1
	w.entity_used[i] = true
	entity_reset(&w.entities[i], i)
	w.free_hint = -1
	return i
}

// FUN_0041d2b0: release a pool slot; it becomes the next one handed out.
entity_free :: proc "contextless" (w: ^World, i: i32) {
	w.free_hint = i
	w.entity_used[i] = false
	w.used_count -= 1
}

// FUN_0041a990: create and initialise one entity of a group.
spawn_entity :: proc(
	s: ^State,
	gi: i32,
	ui: i32,
	req: Spawn_Request,
	time: i32,
	delay: ^i32,
	use_heading: bool,
	heading: i32,
) -> Entity_Ref {
	w := &s.world
	ei := entity_alloc(w)
	if ei == NO_LINK {
		return NO_REF
	}
	g := &w.groups[gi]
	list_append(&g.entities, w.entity_links[:], ei)
	e := entity_at(s, ei)
	u := &s.defs.units[ui]

	// G_Entity::SetUnitRef.
	e.unit = ui
	if u.draw_layer == res_id("hud ") {
		e.casts_shadow = false
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
		e.shields = f32(s.level_number - 1) * u.shields_level_increment + e.shields
		if u.shields_max_amount < e.shields {
			e.shields = u.shields_max_amount
		}
	}

	h := heading
	if !use_heading {
		h = u.initial_heading
	} else if tol := u.initial_heading_tolerance; tol != 0 {
		half := halve(tol)
		h = heading + random_int(&s.rng, -half, half, 0x41aba1)
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

	spawn_location(s, g, e)
	spawn_velocity(s, g, e, use_heading, h, req.owner, req.speed_scale)
	del, des := change_state(s, e, true, u.states[0].name, time)
	if del || des {
		unported(s, 0x41ab1c) // first state is Delete/Destroy
	}
	st := state_of(s, e)
	e.is_air = !u.is_ground_based
	e.shadow_scaled = u.adjust_shadow_loc_for_scaling
	cache_owner_offsets(s, e)

	if u.group_delay_min == u.group_delay_max {
		delay^ += u.group_delay_min
	} else {
		delay^ += random_int(&s.rng, u.group_delay_min, u.group_delay_max, 0x41acc6)
	}
	e.appear_delay = delay^

	if st.cyclic_motion {
		cyclic_velocity(s, e)
	}
	if e.stationary && u.destruct_create_obstacle {
		unported(s, 0x41ad0e) // G_Debris_New
	}
	if st.use_parent_direction && ref_valid(s, e.owner) {
		unported(s, 0x41ad3a) // frame from owner's angle
	}
	if u.include_in_ground_accuracy_count {
		w.ground_targets += 1
	}
	return {ei, e.number}
}

// FUN_0041c540: where in (or around) its group an entity appears.
spawn_location :: proc "contextless" (s: ^State, g: ^Group, e: ^Entity) {
	u := unit_of(s, e)
	xmin, xmax := u.x_offset_min, u.x_offset_max
	ymin, ymax := u.y_offset_min, u.y_offset_max
	loc: Vec
	if xmin == xmax || ymin == ymax {
		if xmin == xmax {
			loc.x = g.loc.x + xmin
		} else {
			lo, hi := xmin, xmax
			if xmax < xmin {
				lo, hi = xmax, xmin
			}
			loc.x = f32(random_int(&s.rng, trunc_i32(lo), trunc_i32(hi), 0x41c718)) + g.loc.x
		}
		if ymin == ymax {
			loc.y = g.loc.y + ymin
		} else {
			lo, hi := ymin, ymax
			if ymax < ymin {
				lo, hi = ymax, ymin
			}
			loc.y = f32(random_int(&s.rng, trunc_i32(lo), trunc_i32(hi), 0x41c7e8)) + g.loc.y
		}
	} else {
		// Both ranges open: a point on (or within) an ellipse.
		v := vector_from_angle(random_int(&s.rng, 0, 359, 0x41c5c1))
		if !u.randomise_initial_loc {
			loc = {v.x * abs(xmax) + g.loc.x, v.y * abs(ymax) + g.loc.y}
		} else {
			r := random_float(&s.rng, 0, abs(xmax), 0x41c5ff)
			loc = {v.x * r + g.loc.x, v.y * r + g.loc.y}
		}
	}
	e.loc = loc
}

// FUN_0041c840: initial velocity.
spawn_velocity :: proc "contextless" (
	s: ^State,
	g: ^Group,
	e: ^Entity,
	use_heading: bool,
	heading: i32,
	owner: Entity_Ref,
	speed_scale: f32,
) {
	if e.stationary {
		e.vel, e.vel_target, e.vel_delta = {}, {}, {}
		return
	}
	u := unit_of(s, e)
	speed := random_float(&s.rng, u.initial_speed_min, u.initial_speed_max, 0x41c8c4)
	angle: i32
	if use_heading || u.initial_heading_set_in_editor {
		angle = invert_angle(heading)
	} else if u.initially_hunts_closest_player {
		unported(s, 0x41c8f0)
		return
	} else if u.do_burst || u.do_implode {
		unported(s, 0x41c9a0)
		return
	} else {
		a: i32
		ok := false
		if !u.use_owner_heading || owner.index == NO_LINK {
			a = u.initial_heading
			ok = true
		} else {
			unported(s, 0x41ca5c) // G_Entity::GetAngleFromSpriteInfo(owner)
			return
		}
		if ok && u.initial_heading_tolerance != 0 {
			half := halve(u.initial_heading_tolerance)
			a += random_int(&s.rng, -half, half, 0x41caaa)
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
		angle = invert_angle(a)
	}
	e.vel = vector_from_angle_and_speed(angle, speed)
	if speed_scale != 1 {
		e.vel *= speed_scale
	}
	e.vel_prev = e.vel
	e.vel_target = e.vel
	e.vel_delta = {}
}

// FUN_0041cbc0: the random drift of a cyclic-motion state.
cyclic_velocity :: proc "contextless" (s: ^State, e: ^Entity) {
	speed: f32 = random_int(&s.rng, 0, 1, 0x41cbe1) == 0 ? 1.4 : 1.0
	whole := random_int(&s.rng, 1, 4, 0x41cc0f)
	frac := f32(random_int(&s.rng, 1, 100, 0x41cc2c)) / 100
	x := f32(whole) + frac
	if random_int(&s.rng, 0, 1, 0x41cc58) != 0 {
		x = -x
	}
	y := f32(random_int(&s.rng, 1, 4, 0x41cc7d)) + frac
	quarter := f32(view_height(s.defs) / 4)
	if quarter < e.loc.y {
		if random_int(&s.rng, 0, 1, 0x41cd11) != 0 {
			y = -y
		}
	}
	len := m_sqrt(trunc_i32(x * x + y * y))
	e.vel = {x / len * speed, y / len * speed}
	e.vel_target = e.vel
	e.vel_prev = e.vel
	e.vel_delta = {x / len * f32(0.2), y / len * f32(0.2)}
}
