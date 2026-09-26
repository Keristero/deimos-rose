package weapon_system

// G_WeaponHandler: a player's air, ground and auxiliary weapons, the
// crosshair that aims ground weapons, and weapon power-ups.

import "dr:sim"
import "dr:sim/lifecycle"
import "dr:sim/stats"

slot_reset :: proc "contextless" (w: ^sim.Weapon_Slot, weapon: i32, time: i32) {
	w^ = sim.Weapon_Slot{weapon = weapon, last = time, last2 = time, flag_b = true}
}

// FUN_00448830: the default weapon (ground if `ground`, else air).
default_weapon :: proc "contextless" (d: ^sim.Defs, ground: bool) -> i32 {
	for &w, i in d.weapons {
		if w.default == sim.WEP_DEFAULT_AIR && !ground {
			return i32(i)
		}
		if w.default == sim.WEP_DEFAULT_GROUND && ground {
			return i32(i)
		}
	}
	return sim.NO_WEAPON
}

// FUN_00448890: the air weapon introduced at exactly this level. This and
// the two below are the original's choices, which never see a new weapon:
// a plugin's weapon chooser (hooks.odin) chooses those.
level_air_weapon :: proc "contextless" (d: ^sim.Defs, level: i32) -> i32 {
	for &w, i in d.weapons {
		if w.type == sim.WEP_AIR && !w.extra && w.minimum_level_available == level {
			return i32(i)
		}
	}
	return sim.NO_WEAPON
}

// FUN_004488e0: the most advanced air weapon available at this level.
best_air_weapon :: proc "contextless" (d: ^sim.Defs, level: i32) -> i32 {
	best := i32(sim.NO_WEAPON)
	for &w, i in d.weapons {
		if w.type != sim.WEP_AIR || w.extra || level > w.maximum_level_available || w.minimum_level_available > level {
			continue
		}
		if best == sim.NO_WEAPON || d.weapons[best].minimum_level_available < w.minimum_level_available {
			best = i32(i)
		}
	}
	return best
}

// G_WepDef_MasterList_GetNextRefPtrByType: the next weapon of a type after
// `current` that is available at this level, wrapping to the first.
next_weapon_of_type :: proc "contextless" (d: ^sim.Defs, type: sim.Res_ID, current: sim.Res_ID, level: i32) -> i32 {
	first := i32(sim.NO_WEAPON)
	seen := false
	for &w, i in d.weapons {
		if w.type != type || w.extra || w.minimum_level_available > level || level > w.maximum_level_available {
			continue
		}
		if current == sim.NONE {
			return i32(i)
		}
		if first == sim.NO_WEAPON {
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
weapons_new_game :: proc(s: ^sim.State, h: sim.Weapons, player: i32, time, level: i32) {
	h.queued_air = sim.NO_WEAPON
	h.queued_ground = sim.NO_WEAPON
	weapons_appear(s, h, false)
	h.appeared = false
	h.player = player
	h.fade_in = s.defs.perm_floats[0x95]
	h.fade_out = s.defs.perm_floats[0x96]
	sim.object_defaults(h.crosshair)
	h.crosshair.draw_layer = {'p', 'l', 'u', 'i'}
	h.aux_count = 0
	if g := default_weapon(s.defs, true); g != sim.NO_WEAPON {
		slot_reset(&h.ground, g, time)
	}
	a := best_air_weapon(s.defs, level)
	if c, ok := sim.weapon_chooser(s); ok {
		a = c.new_game(s, h, level)
	}
	if a != sim.NO_WEAPON {
		slot_reset(&h.air, a, time)
	}
}

// G_WeaponHandler::SetUpForAppearance.
weapons_appear :: proc(s: ^sim.State, h: sim.Weapons, level_start: bool) {
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
	h.air_powerup = sim.Powerup{entity = -1}
	h.air_held = 0
	h.ground_powerup = sim.Powerup{entity = -1}
	h.ground_held = 0
	h.air_idle, h.volleys_left, h.volley_pace, h.ground_pace = 0, 0, 0, 0
	if h.queued_ground != sim.NO_WEAPON {
		change_weapon(s, h, sim.WEP_GROUND, h.queued_ground)
		h.queued_ground = sim.NO_WEAPON
	}
	// A weapon chooser keeps the weapon chosen.
	next := level_start && !sim.weapons_kept(s) ? level_air_weapon(s.defs, sim.single(s, sim.Level_Info).number) : h.queued_air
	if next != sim.NO_WEAPON {
		change_weapon(s, h, sim.WEP_AIR, next)
		h.queued_air = sim.NO_WEAPON
	}
	crosshair_hilite(s, h, false)
	h.crosshair.visibility = 0
	h.crosshair.visibility_target = 100
	h.crosshair.visibility_delta = h.fade_in
}

// G_WeaponHandler::ChangeWeapon.
change_weapon :: proc(s: ^sim.State, h: sim.Weapons, type: sim.Res_ID, weapon: i32) {
	switch type {
	case sim.WEP_AUX:
		sim.unported(s, 0x447130) // auxiliary weapon list
	case sim.WEP_AIR:
		if h.air.weapon == weapon {
			h.queued_air = sim.NO_WEAPON
		} else if h.air_powerup.state == 0 {
			h.air.weapon = weapon
			h.air.count, h.air.pending = 0, 0
			h.air.flag_a, h.air.flag_b = false, true
			h.queued_air = sim.NO_WEAPON
		} else {
			h.queued_air = weapon
		}
	case sim.WEP_GROUND:
		if h.ground.weapon == weapon {
			h.queued_ground = sim.NO_WEAPON
		} else if h.ground_powerup.state == 0 {
			h.ground.weapon = weapon
			h.ground.count, h.ground.pending = 0, 0
			h.ground.flag_a, h.ground.flag_b = false, true
			h.queued_ground = sim.NO_WEAPON
		} else {
			h.queued_ground = weapon
		}
	}
}

// The air weapon Change_Air moves on to from `current`: a weapon chooser's
// choice, else the original's next of its type.
air_weapon_next :: proc "contextless" (s: ^sim.State, h: sim.Weapons, current: i32) -> i32 {
	if c, ok := sim.weapon_chooser(s); ok {
		return c.next(s, h, current)
	}
	if current == sim.NO_WEAPON {
		return sim.NO_WEAPON
	}
	return next_weapon_of_type(s.defs, sim.WEP_AIR, sim.weapon_def(s, current).id, sim.single(s, sim.Level_Info).number)
}

// AirWeapon_GetCurrentOrQueuedWeaponRefPtr.
air_weapon_shown :: proc "contextless" (h: sim.Weapons) -> i32 {
	return h.queued_air != sim.NO_WEAPON ? h.queued_air : h.air.weapon
}

// G_WeaponHandler::Crosshair_Hilite.
crosshair_hilite :: proc "contextless" (s: ^sim.State, h: sim.Weapons, on: bool) {
	if !h.crosshair_shown {
		return
	}
	g := sim.weapon_def(s, h.ground.weapon)
	h.crosshair.frame = on ? g.crosshair_locked_frame : g.crosshair_frame
	h.crosshair_locked = on
}

// G_WeaponHandler::Process. `ground`, `air` and `switch_` are the player's
// fire-ground, fire-air and switch-weapon inputs (film bits 0x10, 0x20,
// 0x40). Returns the power-up result and whether the air weapon changed.
weapons_process :: proc(
	s: ^sim.State,
	h: sim.Weapons,
	at: sim.Vec,
	ground, air, switch_: bool,
	time: i32,
) -> (result: sim.Weapon_Result, air_changed: bool) {
	fire_ground, fire_air, fire_aux := false, false, false
	h.air_held = air ? h.air_held + 1 : 0
	h.ground_held = ground ? h.ground_held + 1 : 0
	// Auto Charge turns the air button around: the power-up charges while
	// it is let go, and a press releases it.
	auto_charge := stats.air_auto_charge(s, h)
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
	if !sim.weapon_def(s, h.air.weapon).auto_repeat {
		air_powerup_process(s, h, time, at, h.air.weapon, auto_charge ? h.air_idle : h.air_held, &result)
	}
	gw := sim.weapon_def(s, h.ground.weapon)
	if gw.powerup_ground_activation_spawn != sim.NONE || gw.powerup_ground_release_spawn != sim.NONE {
		sim.unported(s, 0x44741a) // ground power-up
	}

	if switch_ && !h.prev_switch {
		if n := air_weapon_next(s, h, h.air.weapon); n != sim.NO_WEAPON {
			change_weapon(s, h, sim.WEP_AIR, n)
		}
		h.appeared = true
		air_changed = true
		h.volleys_left = 0
		// U_Sound_Play(id, priority, volume, loop): no draws in this overload.
		if id := s.defs.perm_sounds[0x12]; id != sim.NONE && s.sounds.count < sim.MAX_SOUND_EVENTS {
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
	} else if stats.ground_burst_due(s, h, time) {
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
	lifecycle.calculate_dimensions(s, h.crosshair)
	if h.crosshair.sprite != sim.NONE {
		lifecycle.adjust_visibility_and_tinting(h.crosshair)
	}
	if fire_ground {
		spawn_ground(s, h, at)
	}
	if h.air_powerup.state != 0 {
		h.volleys_left = 0
	}
	if fire_air {
		spawn_air(s, h, at)
		stats.air_volleys_schedule(s, h)
	} else if stats.air_volley_due(s, h) {
		spawn_air(s, h, at)
	}
	if fire_aux {
		sim.unported(s, 0x448590) // Priv_Spawn_Auxilary
	}
	crosshair_hilite(s, h, false)
	return
}

// G_EG_ChangeStateOnWeaponPowerupReleaseByUniqueEntityNum.
powerup_release :: proc(s: ^sim.State, entity: i32, time: i32) {
	walk := sim.walk_entities(s)
	for e in sim.walk_next(&walk) {
		if e.number != entity {
			continue
		}
		// G_Entity::ChangeToWeaponPowerupReleaseState.
		lifecycle.change_to_first(s, e, lifecycle.on_powerup_release, time)
		return
	}
}

// Priv_CheckSpawning_Air. Under Auto Charge holding fire-air autofires.
check_spawning_air :: proc "contextless" (s: ^sim.State, h: sim.Weapons, time: i32) -> bool {
	wd := sim.weapon_def(s, h.air.weapon)
	if h.air.last + stats.air_firing_delay(s, h, h.air.weapon) < time {
		if !(!wd.auto_repeat && !stats.air_auto_charge(s, h) && h.prev_air) {
			h.air.pending += 1
			h.air.last = time
			h.air.last2 = time
			return true
		}
	}
	return false
}

// Priv_CheckSpawning_Auxilary.
check_spawning_aux :: proc "contextless" (s: ^sim.State, h: sim.Weapons, time: i32) -> (any: bool) {
	for &a in h.aux[:h.aux_count] {
		wd := sim.weapon_def(s, a.weapon)
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
check_spawning_ground :: proc "contextless" (s: ^sim.State, h: sim.Weapons, time: i32) -> bool {
	wd := sim.weapon_def(s, h.ground.weapon)
	if !(h.ground.last + wd.delay_between_launches < time) {
		return false
	}
	h.ground.pending = sim.single(s, sim.Level_Info).number - 1 + sim.trunc_i32(s.defs.perm_floats[0x97])
	if mx := sim.trunc_i32(s.defs.perm_floats[0x98]); mx < h.ground.pending {
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
spawn_ground :: proc(s: ^sim.State, h: sim.Weapons, at: sim.Vec) {
	wd := sim.weapon_def(s, h.ground.weapon)
	backwards := stats.ground_fires_backwards(s, h)
	tag := stats.shot_shaper(s, h.player, h.ground.weapon)
	spawns: [stats.MAX_LANES + stats.MAX_EXTRA_SPAWNS]stats.Weapon_Spawn
	for sp in spawns[:stats.weapon_spawns(s, h.ground.weapon, h.player, backwards, spawns[:])] {
		req := sim.spawn_request(sp.unit)
		req.owner_player = h.player
		req.loc = {f32(sp.x) + at.x, f32(sp.y) + at.y}
		req.explicit_heading = sp.set_heading
		req.heading = sp.angle
		req.shaped_by = tag
		reach := max(sim.trunc_i32(backwards ? h.crosshair.loc.y - h.loc.y : h.loc.y - h.crosshair.loc.y), 0)
		req.speed_scale = f32(reach) / f32(abs(wd.crosshair_y_offset))
		lifecycle.eg_request_spawn(s, req)
	}
	if wd.crosshair_spawn_on_activation != sim.NONE {
		lifecycle.spawn_at(s, wd.crosshair_spawn_on_activation, h.crosshair.loc, h.player)
	}
}

// Priv_Spawn_Air.
spawn_air :: proc(s: ^sim.State, h: sim.Weapons, at: sim.Vec) {
	if h.air.pending <= 0 {
		return
	}
	tag := stats.shot_shaper(s, h.player, h.air.weapon)
	spawns: [stats.MAX_LANES + stats.MAX_EXTRA_SPAWNS]stats.Weapon_Spawn
	for sp in spawns[:stats.weapon_spawns(s, h.air.weapon, h.player, false, spawns[:])] {
		req := sim.spawn_request(sp.unit)
		req.owner_player = h.player
		req.loc = {f32(sp.x) + at.x, f32(sp.y) + at.y}
		req.explicit_heading = sp.set_heading
		req.heading = sp.angle
		req.shaped_by = tag
		lifecycle.eg_request_spawn(s, req)
	}
	wd := sim.weapon_def(s, h.air.weapon)
	if fire, ok := sim.weapon_fire(wd); ok && fire.shot != nil {
		fire.shot(s, h, wd, at, sim.single(s, sim.Clock).time)
	}
}

// Priv_AirPowerup_Process: holding fire-air charges a power-up. `held` is
// how long fire-air has been held (air_held), or under Auto Charge how long
// it has been let go (air_idle).
air_powerup_process :: proc(s: ^sim.State, h: sim.Weapons, time: i32, at: sim.Vec, weapon: i32, held: i32, result: ^sim.Weapon_Result) {
	wd := sim.weapon_def(s, weapon)
	if wd.powerup_air_activation_spawn == sim.NONE && wd.powerup_air_release_spawn == sim.NONE {
		return
	}
	p := &h.air_powerup
	top := stats.powerup_max_level(s, h, weapon) // powerup_air_max_power_level, save for stat providers
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
			if wd.powerup_air_activation_spawn != sim.NONE {
				r := lifecycle.spawn_at(s, wd.powerup_air_activation_spawn, at, h.player)
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
		if overload := stats.powerup_overload_time(s, h, weapon); 0 < overload && p.time + overload < time {
			result^ = .Overload
			p.state = 2
			p.time = time
		}
		if p.state == 1 && stats.powerup_level_due(s, h, p, weapon, time) {
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
		// A plugin's weapon may let its charge go its own way.
		fire, fired := sim.weapon_fire(wd)
		if p.level < 1 {
			p.state = 0
			p.time = time
			p.level = 0
			p.percent = 0
			if h.queued_air != sim.NO_WEAPON {
				change_weapon(s, h, sim.WEP_AIR, h.queued_air)
				h.queued_air = sim.NO_WEAPON
			}
		} else if fired && fire.release != nil {
			fire.release(s, h, wd, at, p.level, time)
			p.release_time = time
			p.level = 0
			p.percent = 0
		} else if p.release_time + wd.powerup_air_time_between_release_spawns < time {
			if fired && fire.volley != nil {
				fire.volley(s, h, wd, at)
			} else {
				lifecycle.spawn_at(s, wd.powerup_air_release_spawn, at, h.player)
			}
			p.release_time = time
			p.level -= 1
			p.percent = percent(p.level, top)
		}
	}
}
