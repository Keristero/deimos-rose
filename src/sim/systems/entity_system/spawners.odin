package entity_system

// Spawners: an entity's spawn sets, run by its state, and the pacing a
// shaped weapon gives the shots it spawns (sim/stats).

import "dr:sim"
import "dr:sim/lifecycle"
import "dr:sim/stats"
import "dr:sim/systems/movement_system"

// G_Entity::SpawnControl: run the current state's spawn sets.
spawn_control :: proc(s: ^sim.State, e: sim.Entity, time: i32) {
	sim.record_event(s, sim.Event{kind = .Spawn_Control, unit = sim.unit_of(s, e).id, number = e.number})
	movement_system.rotate_as_required(s, e, time)
	if !e.spawning {
		return
	}
	st := sim.state_of(s, e)
	for &set, i in st.spawn_sets {
		info := &e.spawn_info[i]
		if set.spawn == sim.NONE || !info.active || info.delay < 0 || (e.fleeing && !set.spawn_if_fleeing) {
			continue
		}
		if set.dont_spawn_offscreen && info.left >= 1 && info.left >= info.volley && !movement_system.within_game_area(s, e) {
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
				info.gap = sim.roll_int(s, set.delay_between_entities_min, set.delay_between_entities_max, 0x414c7c)
				info.volley = sim.roll_int(s, set.num_in_volley_min, set.num_in_volley_max, 0x414c91)
				info.left = info.volley
				info.delay = sim.roll_int(s, set.rate_min, set.rate_max, 0x414cac)
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
				info.gap = sim.roll_int(s, set.delay_between_entities_min, set.delay_between_entities_max, 0x414c39)
			}
		}
		if fire {
			spawn_child(s, e, &set)
		}
	}
}

// The spawn at the end of SpawnControl. A spawner fired by a weapon with a
// plugin may reshape the spawn first (shaped_spawn_child).
@(private = "file")
spawn_child :: proc(s: ^sim.State, e: sim.Entity, set: ^sim.Spawn_Set_Def) {
	if e.shaped_by != 0 && e.shaped_depth == 0 && shaped_spawn_child(s, e, set) {
		return
	}
	spawn_child_set(s, e, set)
}

// Place the child relative to its parent, optionally rotated with the
// parent's facing.
spawn_child_set :: proc(s: ^sim.State, e: sim.Entity, set: ^sim.Spawn_Set_Def) {
	ci := sim.unit_index(s.defs, set.spawn)
	child: ^sim.Unit = ci >= 0 ? &s.defs.units[ci] : nil
	// Terrain effects only come from mobile parents that allow them.
	if child != nil && child.terrain_effect && !(!e.stationary && e.terrain_effects) {
		return
	}
	req := sim.spawn_request(set.spawn)
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
		a := lifecycle.angle_from_sprite(s, e)
		if set.set_heading {
			a += set.heading_degrees
			if a > 359 {
				a -= 360
			}
			explicit = true
			req.heading = a
		}
		c, sn := sim.m_cos(a), sim.m_sin(a)
		ox, oy: i32
		if scaled_offset {
			x, y := f32(set.x_offset) * e.scale, f32(set.y_offset) * e.scale
			ox, oy = sim.trunc_i32(x * c - y * sn), sim.trunc_i32(x * sn + y * c)
		} else {
			x, y := f32(set.x_offset), f32(set.y_offset)
			ox, oy = sim.trunc_i32(x * c - y * sn), sim.trunc_i32(x * sn + y * c)
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
	if e.shaped_by != 0 {
		req.shaped_by = e.shaped_by
		req.shaped_depth = e.shaped_depth + 1
	}
	lifecycle.eg_request_spawn(s, req)
}

// spawn_control for a spawner whose volleys its stats have sped up: its
// spawn sets run on their own clock, spawn_pace hundredths of a step per
// step, so a 30% shorter volley delay runs them 100/70 as fast.
paced_spawn_control :: proc(s: ^sim.State, e: sim.Entity) {
	e.pace_acc += e.spawn_pace
	for e.pace_acc >= 100 && !e.deleted {
		e.pace_acc -= 100
		spawn_control(s, e, e.spawn_clock)
		e.spawn_clock += 1
	}
}

// One of a shaped spawner's spawn sets firing (spawn_child). Handles its
// projectile sets -- extending the lanes and firing to the sides -- and
// returns false for the rest, which spawn as they are.
shaped_spawn_child :: proc(s: ^sim.State, e: sim.Entity, set: ^sim.Spawn_Set_Def) -> bool {
	w, ok := stats.shaped_weapon(s, e.shaped_by)
	if !ok || e.owner_player < 0 || e.owner_player >= sim.MAX_PLAYERS || !stats.unit_is_projectile(s, set.spawn) {
		return false
	}
	p := e.owner_player
	extra := sim.stat_of(s, p, .Extra_Projectiles, w).extra
	side := sim.stat_of(s, p, .Side_Firing_Volley, w).enabled
	if extra <= 0 && !side {
		return false
	}
	st := sim.state_of(s, e)
	me := -1
	base: [stats.MAX_LANES]stats.Lane
	n := 0
	for &other, i in st.spawn_sets {
		if n < stats.MAX_LANES && stats.unit_is_projectile(s, other.spawn) {
			if &other == set {
				me = i
			}
			base[n] = {f32(other.x_offset), f32(other.y_offset), other.set_heading ? stats.signed_angle(other.heading_degrees) : 0, i32(i)}
			n += 1
		}
	}
	emit :: proc(s: ^sim.State, e: sim.Entity, set: ^sim.Spawn_Set_Def, x, y: i32, heading: i32, explicit: bool) {
		alt := set^
		alt.x_offset, alt.y_offset = x, y
		alt.set_heading = explicit
		alt.heading_degrees = heading
		spawn_child_set(s, e, &alt)
	}
	if extra > 0 && n > 0 {
		stats.lanes_sort(base[:n])
		lanes: [stats.MAX_LANES]stats.Lane
		m := stats.lanes_extend(base[:n], extra, lanes[:])
		for l in lanes[:m] {
			if base[l.src].src != i32(me) {
				continue
			}
			a := stats.round_i32(l.angle)
			emit(s, e, set, stats.round_i32(l.x), stats.round_i32(l.y), stats.wrap_angle(a), set.set_heading || a != 0)
		}
	} else {
		spawn_child_set(s, e, set)
	}
	// Side fire: each forward-facing set also fires outward, left of the
	// centre line to the left and right of it to the right.
	if side && (!set.set_heading || set.heading_degrees == 0) {
		if set.x_offset <= 0 {
			emit(s, e, set, set.x_offset, set.y_offset, 270, true)
		}
		if set.x_offset >= 0 {
			emit(s, e, set, set.x_offset, set.y_offset, 90, true)
		}
	}
	return true
}
