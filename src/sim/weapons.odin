package sim

// G_WeaponHandler: a player's air, ground and auxiliary weapons, the
// crosshair that aims ground weapons, and weapon power-ups.
//
// Weapons are indices into Defs.weapons (-1 for none) where the original
// holds G_WepDef pointers. Offsets are relative to the handler, which sits at
// G_Player + 0x235.

NO_WEAPON :: -1

// Weapon slot bookkeeping shared by the air (+0x5d) and ground (+0x77) slots.
Weapon_Slot :: struct {
	weapon:   i32,  // +0x00 current definition
	last:     i32,  // +0x04 time of the last launch
	last2:    i32,  // +0x08
	count:    i32,  // +0x0c
	pending:  i32,  // +0x10 launches due (air) / bombs left in the burst (ground)
	flag_a:   bool, // +0x14
	flag_b:   bool, // +0x15
}

// A charge-and-release power-up (air at +0x11, ground at +0x35).
Powerup :: struct {
	state:        i32, // 0 idle, 1 charging, 2 overloaded, 3 releasing
	time:         i32,
	entity:       i32, // unique number of the activation spawn
	level_time:   i32,
	level:        i32,
	percent:      f32,
	release_time: i32,
	pace:         i32, // not the original's: see powerup_level_due
}

MAX_AUX :: 8

Weapon_Handler :: struct {
	loc:             Vec,  // +0x00 the player's position (UpdateLoc)
	appeared:        bool, // +0x08
	prev_ground:     bool, // +0x09 last step's fire-ground input
	prev_air:        bool, // +0x0a
	prev_switch:     bool, // +0x0b
	air_powerup:     Powerup, // +0x11
	air_held:        i32,  // +0x2d steps fire-air has been held
	ground_powerup:  Powerup, // +0x35
	ground_held:     i32,  // +0x51
	queued_air:      i32,  // +0x55 takes effect when the power-up is idle
	queued_ground:   i32,  // +0x59
	air:             Weapon_Slot, // +0x5d
	aux:             [MAX_AUX]Weapon_Slot, // +0x73 (a list in the original)
	aux_count:       i32,
	ground:          Weapon_Slot, // +0x77
	// +0x8d: the crosshair, its own entity (Weapons).
	player:          i32,  // +0x119
	fade_in:         f32,  // +0x11d perm float 0x95
	fade_out:        f32,  // +0x121 perm float 0x96
	// Not the original's; used only by passives (sim/passives.odin).
	air_idle:        i32,  // steps fire-air has been let go, for Auto Charge
	volleys_left:    i32,  // extra volleys still owed by the last shot
	volley_pace:     i32,  // hundredths of a step towards the next one
	ground_pace:     i32,  // hundredths of a step towards the next bomb
	// Not the original's; used only by New Weapons (sim/loadout.odin): the
	// air weapons held, those switched between and the rest.
	loadout:         [LOADOUT_SLOTS]i32,
	spare:           [MAX_SPARE]i32,
}

// The crosshair entity's own component; its Game_Object is the rest of it.
Crosshair :: struct {
	crosshair_shown:  bool, // +0x117
	crosshair_locked: bool, // +0x118
}

// A player's weapon handler and crosshair, found once (weapons_of).
Weapons :: struct {
	using handler: ^Weapon_Handler,
	crosshair:     ^Game_Object,
	using aim:     ^Crosshair,
}

crosshair_components :: proc "contextless" () -> Component_Mask {
	return {component_id(Game_Object), component_id(Crosshair)}
}

weapons_of :: proc "contextless" (s: ^State, i: i32) -> Weapons {
	e := s.ecs
	return {
		handler   = get(e, player_entity(i), Weapon_Handler),
		crosshair = get(e, crosshair_entity(i), Game_Object),
		aim       = get(e, crosshair_entity(i), Crosshair),
	}
}

Weapon_Result :: enum i32 {
	None     = 0,
	Overload = 1, // air power-up held too long
	Released = 2,
}

weapon_def :: #force_inline proc "contextless" (s: ^State, i: i32) -> ^Weapon {
	return &s.defs.weapons[i]
}

slot_reset :: proc "contextless" (w: ^Weapon_Slot, weapon: i32, time: i32) {
	w^ = Weapon_Slot{weapon = weapon, last = time, last2 = time, flag_b = true}
}

// FUN_00448830: the default weapon (ground if `ground`, else air).
default_weapon :: proc "contextless" (d: ^Defs, ground: bool) -> i32 {
	for &w, i in d.weapons {
		if w.default == WEP_DEFAULT_AIR && !ground {
			return i32(i)
		}
		if w.default == WEP_DEFAULT_GROUND && ground {
			return i32(i)
		}
	}
	return NO_WEAPON
}

// FUN_00448890: the air weapon introduced at exactly this level. This and
// the two below are the original's choices, which never see a new weapon:
// New Weapons chooses through the loadout instead.
level_air_weapon :: proc "contextless" (d: ^Defs, level: i32) -> i32 {
	for &w, i in d.weapons {
		if w.type == WEP_AIR && !w.extra && w.minimum_level_available == level {
			return i32(i)
		}
	}
	return NO_WEAPON
}

// FUN_004488e0: the most advanced air weapon available at this level.
best_air_weapon :: proc "contextless" (d: ^Defs, level: i32) -> i32 {
	best := i32(NO_WEAPON)
	for &w, i in d.weapons {
		if w.type != WEP_AIR || w.extra || level > w.maximum_level_available || w.minimum_level_available > level {
			continue
		}
		if best == NO_WEAPON || d.weapons[best].minimum_level_available < w.minimum_level_available {
			best = i32(i)
		}
	}
	return best
}

// G_WepDef_MasterList_GetNextRefPtrByType: the next weapon of a type after
// `current` that is available at this level, wrapping to the first.
next_weapon_of_type :: proc "contextless" (d: ^Defs, type: Res_ID, current: Res_ID, level: i32) -> i32 {
	first := i32(NO_WEAPON)
	seen := false
	for &w, i in d.weapons {
		if w.type != type || w.extra || w.minimum_level_available > level || level > w.maximum_level_available {
			continue
		}
		if current == NONE {
			return i32(i)
		}
		if first == NO_WEAPON {
			first = i32(i)
		}
		if current == w.id {
			seen = true
		} else if seen {
			return i32(i)
		}
	}
	return first
}

// G_WeaponHandler::SetUpAtNewGameStart.
weapons_new_game :: proc(s: ^State, h: Weapons, player: i32, time, level: i32) {
	h.queued_air = NO_WEAPON
	h.queued_ground = NO_WEAPON
	weapons_appear(s, h, false)
	h.appeared = false
	h.player = player
	h.fade_in = s.defs.perm_floats[0x95]
	h.fade_out = s.defs.perm_floats[0x96]
	object_defaults(h.crosshair)
	h.crosshair.draw_layer = {'p', 'l', 'u', 'i'}
	h.aux_count = 0
	if g := default_weapon(s.defs, true); g != NO_WEAPON {
		slot_reset(&h.ground, g, time)
	}
	h.loadout = NO_WEAPON
	h.spare = NO_WEAPON
	a := best_air_weapon(s.defs, level)
	if s.session.loadout {
		a = loadout_new_game(s, h, level)
	}
	if a != NO_WEAPON {
		slot_reset(&h.air, a, time)
	}
}

// G_WeaponHandler::SetUpForAppearance.
weapons_appear :: proc(s: ^State, h: Weapons, level_start: bool) {
	h.loc = {}
	h.prev_ground, h.prev_air, h.prev_switch = false, false, false
	h.appeared = true
	h.ground.last, h.ground.last2, h.ground.pending = 0, 0, 0
	h.ground.flag_a, h.ground.flag_b = false, true
	h.air.last, h.air.last2, h.air.pending = 0, 0, 0
	h.air.flag_a, h.air.flag_b = false, true
	for &a in h.aux[:h.aux_count] {
		a.last, a.last2, a.pending = 0, 0, 0
		a.flag_a, a.flag_b = false, true
	}
	h.air_powerup = Powerup{entity = -1}
	h.air_held = 0
	h.ground_powerup = Powerup{entity = -1}
	h.ground_held = 0
	h.air_idle, h.volleys_left, h.volley_pace, h.ground_pace = 0, 0, 0, 0
	if h.queued_ground != NO_WEAPON {
		change_weapon(s, h, WEP_GROUND, h.queued_ground)
		h.queued_ground = NO_WEAPON
	}
	// New Weapons keeps the weapon chosen: a new one waits in the loadout.
	next := level_start && !s.session.loadout ? level_air_weapon(s.defs, single(s, Level_Info).number) : h.queued_air
	if next != NO_WEAPON {
		change_weapon(s, h, WEP_AIR, next)
		h.queued_air = NO_WEAPON
	}
	crosshair_hilite(s, h, false)
	h.crosshair.visibility = 0
	h.crosshair.visibility_target = 100
	h.crosshair.visibility_delta = h.fade_in
}

// G_WeaponHandler::ChangeWeapon.
change_weapon :: proc(s: ^State, h: Weapons, type: Res_ID, weapon: i32) {
	switch type {
	case WEP_AUX:
		unported(s, 0x447130) // auxiliary weapon list
	case WEP_AIR:
		if h.air.weapon == weapon {
			h.queued_air = NO_WEAPON
		} else if h.air_powerup.state == 0 {
			h.air.weapon = weapon
			h.air.count, h.air.pending = 0, 0
			h.air.flag_a, h.air.flag_b = false, true
			h.queued_air = NO_WEAPON
		} else {
			h.queued_air = weapon
		}
	case WEP_GROUND:
		if h.ground.weapon == weapon {
			h.queued_ground = NO_WEAPON
		} else if h.ground_powerup.state == 0 {
			h.ground.weapon = weapon
			h.ground.count, h.ground.pending = 0, 0
			h.ground.flag_a, h.ground.flag_b = false, true
			h.queued_ground = NO_WEAPON
		} else {
			h.queued_ground = weapon
		}
	}
}

// The air weapon Change_Air moves on to from `current`: the next in the
// loadout under New Weapons, else the original's next of its type.
air_weapon_next :: proc "contextless" (s: ^State, h: Weapons, current: i32) -> i32 {
	if s.session.loadout {
		return loadout_next(h, current)
	}
	if current == NO_WEAPON {
		return NO_WEAPON
	}
	return next_weapon_of_type(s.defs, WEP_AIR, weapon_def(s, current).id, single(s, Level_Info).number)
}

// AirWeapon_GetCurrentOrQueuedWeaponRefPtr.
air_weapon_shown :: proc "contextless" (h: Weapons) -> i32 {
	return h.queued_air != NO_WEAPON ? h.queued_air : h.air.weapon
}

// G_WeaponHandler::Crosshair_Hilite.
crosshair_hilite :: proc "contextless" (s: ^State, h: Weapons, on: bool) {
	if !h.crosshair_shown {
		return
	}
	g := weapon_def(s, h.ground.weapon)
	h.crosshair.frame = on ? g.crosshair_locked_frame : g.crosshair_frame
	h.crosshair_locked = on
}

// G_WeaponHandler::Process. `ground`, `air` and `switch_` are the player's
// fire-ground, fire-air and switch-weapon inputs (film bits 0x10, 0x20,
// 0x40). Returns the power-up result and whether the air weapon changed.
weapons_process :: proc(
	s: ^State,
	h: Weapons,
	at: Vec,
	ground, air, switch_: bool,
	time: i32,
) -> (result: Weapon_Result, air_changed: bool) {
	fire_ground, fire_air, fire_aux := false, false, false
	h.air_held = air ? h.air_held + 1 : 0
	h.ground_held = ground ? h.ground_held + 1 : 0
	// Auto Charge turns the air button around: the power-up charges while
	// it is let go, and a press releases it.
	auto_charge := air_auto_charge(s, h)
	h.air_idle = air || h.air_powerup.state != 0 ? 0 : h.air_idle + 1
	release := auto_charge ? air && !h.prev_air : !air
	if release && (h.air_powerup.state == 1 || h.air_powerup.state == 2) {
		h.air_powerup.state = 3
		h.air_powerup.time = time
		powerup_release(s, h.air_powerup.entity, time)
		result = .Released
	}
	if !ground && (h.ground_powerup.state == 1 || h.ground_powerup.state == 2) {
		h.ground_powerup.state = 3
		h.ground_powerup.time = time
		powerup_release(s, h.ground_powerup.entity, time)
		result = .Released
	}
	if !weapon_def(s, h.air.weapon).auto_repeat {
		air_powerup_process(s, h, time, at, h.air.weapon, auto_charge ? h.air_idle : h.air_held, &result)
	}
	gw := weapon_def(s, h.ground.weapon)
	if gw.powerup_ground_activation_spawn != NONE || gw.powerup_ground_release_spawn != NONE {
		unported(s, 0x44741a) // ground power-up
	}

	if switch_ && !h.prev_switch {
		if n := air_weapon_next(s, h, h.air.weapon); n != NO_WEAPON {
			change_weapon(s, h, WEP_AIR, n)
		}
		h.appeared = true
		air_changed = true
		h.volleys_left = 0
		// U_Sound_Play(id, priority, volume, loop): no draws in this overload.
		if id := s.defs.perm_sounds[0x12]; id != NONE && s.sounds.count < MAX_SOUND_EVENTS {
			s.sounds.events[s.sounds.count] = {id, 100, 0x4b, 1, true}
			s.sounds.count += 1
		}
	} else if air && h.air_powerup.state == 0 {
		fire_air = check_spawning_air(s, h, time)
		fire_aux = check_spawning_aux(s, h, time)
	}

	if h.ground.pending < 1 {
		if ground && !h.prev_ground && h.ground_powerup.state == 0 {
			fire_ground = check_spawning_ground(s, h, time)
		}
	} else if ground_burst_due(s, h, time) {
		h.ground.pending -= 1
		fire_ground = true
		h.ground.last2 = time
		h.ground.last = time
	}
	h.prev_ground, h.prev_air, h.prev_switch = ground, air, switch_
	h.crosshair_shown = true
	h.crosshair.sprite = gw.crosshair_face
	h.crosshair.frame = gw.crosshair_frame
	h.crosshair_locked = false
	calculate_dimensions(s, h.crosshair)
	if h.crosshair.sprite != NONE {
		adjust_visibility_and_tinting(h.crosshair)
	}
	if fire_ground {
		spawn_ground(s, h, at)
	}
	if h.air_powerup.state != 0 {
		h.volleys_left = 0
	}
	if fire_air {
		spawn_air(s, h, at)
		air_volleys_schedule(s, h)
	} else if air_volley_due(s, h) {
		spawn_air(s, h, at)
	}
	if fire_aux {
		unported(s, 0x448590) // Priv_Spawn_Auxilary
	}
	crosshair_hilite(s, h, false)
	return
}

// G_EG_ChangeStateOnWeaponPowerupReleaseByUniqueEntityNum.
powerup_release :: proc(s: ^State, entity: i32, time: i32) {
	w := &s.world
	g := w.active.head
	for g != NO_LINK {
		i := w.groups[g].entities.head
		for i != NO_LINK {
			if e := entity_at(s, i); e.number == entity {
				// G_Entity::ChangeToWeaponPowerupReleaseState: the first state
				// flagged for a weapon-powerup release.
				for &st in unit_of(s, e).states {
					if st.use_this_state_on_weapon_powerup_release {
						_, _ = change_state(s, e, false, st.name, time)
						break
					}
				}
				return
			}
			i = w.entity_links[i].next
		}
		g = w.group_links[g].next
	}
}

// Priv_CheckSpawning_Air. Under Auto Charge holding fire-air autofires.
check_spawning_air :: proc "contextless" (s: ^State, h: Weapons, time: i32) -> bool {
	wd := weapon_def(s, h.air.weapon)
	if h.air.last + air_firing_delay(s, h, h.air.weapon) < time {
		if !(!wd.auto_repeat && !air_auto_charge(s, h) && h.prev_air) {
			h.air.pending += 1
			h.air.last = time
			h.air.last2 = time
			return true
		}
	}
	return false
}

// Priv_CheckSpawning_Auxilary.
check_spawning_aux :: proc "contextless" (s: ^State, h: Weapons, time: i32) -> (any: bool) {
	for &a in h.aux[:h.aux_count] {
		wd := weapon_def(s, a.weapon)
		if a.last + wd.delay_between_launches < time && !(!wd.auto_repeat && h.prev_air) {
			a.pending += 1
			a.last = time
			a.last2 = time
			any = true
		}
	}
	return
}

// Priv_CheckSpawning_Ground: start a burst of bombs, one more per level.
check_spawning_ground :: proc "contextless" (s: ^State, h: Weapons, time: i32) -> bool {
	wd := weapon_def(s, h.ground.weapon)
	if !(h.ground.last + wd.delay_between_launches < time) {
		return false
	}
	h.ground.pending = single(s, Level_Info).number - 1 + trunc_i32(s.defs.perm_floats[0x97])
	if mx := trunc_i32(s.defs.perm_floats[0x98]); mx < h.ground.pending {
		h.ground.pending = mx
	}
	h.ground.pending -= 1
	h.ground.last = time
	h.ground.last2 = time
	h.ground_pace = 0
	return true
}

// Priv_Spawn_Ground: each spawn record of the ground weapon, its speed scaled
// by the crosshair's distance, then the crosshair's activation spawn. A
// passive may add lanes, or turn the weapon behind the ship (weapon_spawns).
spawn_ground :: proc(s: ^State, h: Weapons, at: Vec) {
	wd := weapon_def(s, h.ground.weapon)
	backwards := ground_fires_backwards(s, h)
	tag := weapon_passive_tag(s, h.player, h.ground.weapon)
	spawns: [MAX_LANES + MAX_EXTRA_SPAWNS]Weapon_Spawn
	for sp in spawns[:weapon_spawns(s, h.ground.weapon, h.player, backwards, spawns[:])] {
		req := spawn_request(sp.unit)
		req.owner_player = h.player
		req.loc = {f32(sp.x) + at.x, f32(sp.y) + at.y}
		req.explicit_heading = sp.set_heading
		req.heading = sp.angle
		req.passive_tag = tag
		reach := max(trunc_i32(backwards ? h.crosshair.loc.y - h.loc.y : h.loc.y - h.crosshair.loc.y), 0)
		req.speed_scale = f32(reach) / f32(abs(wd.crosshair_y_offset))
		eg_request_spawn(s, req)
	}
	if wd.crosshair_spawn_on_activation != NONE {
		req := spawn_request(wd.crosshair_spawn_on_activation)
		req.owner_player = h.player
		req.loc = h.crosshair.loc
		eg_request_spawn(s, req)
	}
}

// Priv_Spawn_Air.
spawn_air :: proc(s: ^State, h: Weapons, at: Vec) {
	if h.air.pending <= 0 {
		return
	}
	tag := weapon_passive_tag(s, h.player, h.air.weapon)
	spawns: [MAX_LANES + MAX_EXTRA_SPAWNS]Weapon_Spawn
	for sp in spawns[:weapon_spawns(s, h.air.weapon, h.player, false, spawns[:])] {
		req := spawn_request(sp.unit)
		req.owner_player = h.player
		req.loc = {f32(sp.x) + at.x, f32(sp.y) + at.y}
		req.explicit_heading = sp.set_heading
		req.heading = sp.angle
		req.passive_tag = tag
		eg_request_spawn(s, req)
	}
	if wd := weapon_def(s, h.air.weapon); wd.beam.on {
		beam_fire(s, h, wd, at, wd.beam.damage, wd.beam.width, false, single(s, Clock).time)
	}
}

// Priv_AirPowerup_Process: holding fire-air charges a power-up. `held` is
// how long fire-air has been held (air_held), or under Auto Charge how long
// it has been let go (air_idle).
air_powerup_process :: proc(s: ^State, h: Weapons, time: i32, at: Vec, weapon: i32, held: i32, result: ^Weapon_Result) {
	wd := weapon_def(s, weapon)
	if wd.powerup_air_activation_spawn == NONE && wd.powerup_air_release_spawn == NONE {
		return
	}
	p := &h.air_powerup
	top := powerup_max_level(s, h, weapon) // powerup_air_max_power_level, save for passives
	percent :: proc "contextless" (level, max_level: i32) -> f32 {
		v := f32(level) / f32(max_level) * 100
		if v < 1 {
			return 0
		} else if 100 < v {
			return 100
		}
		return v
	}
	switch p.state {
	case 0:
		if wd.powerup_air_time_until_activation <= held {
			h.air_held = 0
			p.pace = 0
			if wd.powerup_air_activation_spawn != NONE {
				req := spawn_request(wd.powerup_air_activation_spawn)
				req.owner_player = h.player
				req.loc = at
				r := eg_request_spawn(s, req)
				p.entity = r.number
			}
			p.state = 1
			p.time = time
			p.level_time = time
			p.level = 0
			p.release_time = time
			p.percent = 0
		}
	case 1:
		if overload := powerup_overload_time(s, h, weapon); 0 < overload && p.time + overload < time {
			result^ = .Overload
			p.state = 2
			p.time = time
		}
		if p.state == 1 && powerup_level_due(s, h, p, weapon, time) {
			p.level += 1
			p.percent = percent(p.level, top)
			if top < p.level {
				p.level = top
				p.percent = 100
				if wd.powerup_air_do_release_on_max_power_level {
					p.state = 3
					p.time = time
					powerup_release(s, p.entity, time)
					result^ = .Released
				}
			} else {
				p.level_time = time
			}
		}
	case 2:
	case 3:
		if p.level < 1 {
			p.state = 0
			p.time = time
			p.level = 0
			p.percent = 0
			if h.queued_air != NO_WEAPON {
				change_weapon(s, h, WEP_AIR, h.queued_air)
				h.queued_air = NO_WEAPON
			}
		} else if wd.beam.on {
			// A beam's charge goes in one shot, however many levels it holds.
			beam_release(s, h, wd, at, p.level, time)
			p.release_time = time
			p.level = 0
			p.percent = 0
		} else if p.release_time + wd.powerup_air_time_between_release_spawns < time {
			if wd.aimed_release {
				aimed_release_spawn(s, h, wd, at)
			} else {
				req := spawn_request(wd.powerup_air_release_spawn)
				req.owner_player = h.player
				req.loc = at
				eg_request_spawn(s, req)
			}
			p.release_time = time
			p.level -= 1
			p.percent = percent(p.level, top)
		}
	}
}
