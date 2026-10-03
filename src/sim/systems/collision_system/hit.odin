package collision_system

// Collisions and damage: entities against players, shots and wreckage
// (contact.odin), what a hit does (G_Entity::Hit, here), and what happens to
// a player that is hit (player_damage.odin).

import "dr:sim"
import "dr:sim/lifecycle"
import "dr:sim/stats"

// Sound settings stored inline in a unit definition (hit sounds).
@(private = "file")
unit_sound :: proc "contextless" (id: sim.Res_ID, min_vol, max_vol, prio: i32, min_pitch, max_pitch: f32) -> sim.Sound_Settings {
	return {id, min_vol, max_vol, prio, min_pitch, max_pitch}
}

// G_Entity::Hit. Returns the shield damage dealt.
entity_hit :: proc(s: ^sim.State, e: sim.Entity, damage: f32, player: i32, time: i32) -> f32 {
	if e.deleted {
		return 0
	}
	if time < sim.hit_gap(s) + e.last_hit {
		return 0 // Entity_HitDelay
	}
	e.last_hit = time
	before := e.shields
	e.shields -= damage
	if e.shields < 0 {
		e.shields = 0
	}
	dealt := before - e.shields
	if before <= 0 {
		return dealt
	}
	u := sim.unit_of(s, e)
	st := sim.state_of(s, e)
	if st.invulnerable_shields_do_not_deplete_on_collision {
		e.shields = before
	}
	sim.hit_record(s, {loc = e.loc, damage = damage, shields = before, scrolls_sideways = e.scrolls_sideways, killed = e.shields <= 0})
	if st.on_hit_change_state_delay != 0 && st.on_hit_change_to != "" &&
	   e.hit_state_time + st.on_hit_change_state_delay < time {
		e.hit_state_time = time
		// The original ignores ChangeState's delete/destroy results here.
		_, _ = lifecycle.change_state(s, e, false, st.on_hit_change_to, time)
		if e.deleted {
			return dealt
		}
		st = sim.state_of(s, e)
	}
	if e.shields <= 0 {
		entity_depleted(s, e, player, time)
		return dealt
	}
	if !st.do_not_glow_on_collision {
		lifecycle.glow_start(e.obj, 0x7fff, 6, false)
	}
	if u.hit_particles != sim.NONE {
		sim.particle_burst(s, e.loc, u.hit_particles_color, u.hit_particles, u.is_ground_based)
	}
	snd: sim.Sound_Settings
	if st.invulnerable_shields_do_not_deplete_on_collision {
		snd = unit_sound(u.unshielded_sound, u.unshielded_sound_min_volume, u.unshielded_sound_max_volume,
			u.unshielded_sound_priority, u.unshielded_sound_min_pitch, u.unshielded_sound_max_pitch)
	} else {
		snd = unit_sound(u.shield_sound, u.shield_sound_min_volume, u.shield_sound_max_volume,
			u.shield_sound_priority, u.shield_sound_min_pitch, u.shield_sound_max_pitch)
	}
	if snd.id != sim.NONE {
		sim.sound_play(s, snd, true)
	}
	if st.collision_spawn != sim.NONE && (st.collision_repeat_spawns || e.collision_count == 0) &&
	   e.collision_time + st.collision_spawn_delay <= time {
		lifecycle.spawn_from(s, e, st.collision_spawn)
		e.collision_time = time
		e.collision_count += 1
	}
	return dealt
}

// What emptying `e`'s shields does, from G_Entity::Hit: `player` scores
// for it, and it is destroyed, or changes to its depletion state.
@(private = "file")
entity_depleted :: proc(s: ^sim.State, e: sim.Entity, player: i32, time: i32) {
	if player >= 0 && player < sim.MAX_PLAYERS {
		player_score(s, sim.player_at(s, player), sim.unit_of(s, e).score, false)
	}
	if !e.has_depletion_state {
		lifecycle.entity_destroy(s, e, player, time)
	} else {
		change_state_on_depletion(s, e, time)
	}
}

// Damage that is not a hit, for new content that harms what lingers in
// it: it neither waits for the target's hit delay nor starts it, so the
// shots that hit it are not turned away, and it shows nothing of a hit's
// (no glow, sound, particles, collision spawn or change of state). An
// entity whose state does not deplete takes none. Emptying its shields
// does what a hit's would. Returns the shield damage dealt.
entity_damage :: proc(s: ^sim.State, e: sim.Entity, damage: f32, player: i32, time: i32) -> f32 {
	if e.deleted || e.shields <= 0 || sim.state_of(s, e).invulnerable_shields_do_not_deplete_on_collision {
		return 0
	}
	before := e.shields
	e.shields = max(before - damage, 0)
	if e.shields <= 0 {
		entity_depleted(s, e, player, time)
	}
	return before - e.shields
}

// G_Entity::Priv_ChangeStateOnShieldDepletion: the first state flagged for it.
change_state_on_depletion :: proc(s: ^sim.State, e: sim.Entity, time: i32) {
	lifecycle.change_to_first(s, e, lifecycle.on_shield_depletion, time)
}

// Who takes a hit meant for `e`: its owner, when e's state passes hits on
// and `owner` is still there, else e itself.
hit_taker :: proc "contextless" (s: ^sim.State, e: sim.Entity, passes: bool, owner: sim.Entity_Ref) -> sim.Entity {
	if passes && sim.ref_valid(s, owner) {
		return sim.entity_at(s, owner.index)
	}
	return e
}

// The hit half of FUN_0041b920: a shot `e` meets a target `o`; each damages
// the other (or its owner, when the state passes hits on). The target's pass
// is checked against, and goes to, the *shot's* owner, not the target's --
// faithful to the original.
collide_entities :: proc(s: ^sim.State, e, o: sim.Entity, time: i32) {
	eu, ou := sim.unit_of(s, e), sim.unit_of(s, o)
	e_passes := sim.prefab_has(s, sim.prefab_of(s, e), Passes_Hits_To_Owner)
	shot_hit(s, o, hit_taker(s, e, e_passes, e.owner), stats.shot_damage(s, o, ou.damage), time)
	o_passes := sim.prefab_has(s, sim.prefab_of(s, o), Passes_Hits_To_Owner)
	damage := stats.shot_damage(s, e, eu.damage)
	if e.ground > 0 && ou.is_ground_based {
		// An air shot on a ground target (Hits_Ground) deals its share.
		damage *= e.ground
	}
	shot_hit(s, e, hit_taker(s, o, o_passes, e.owner), damage, time)
}

// `by` hits `target` for `damage`: entity_hit, for the player `by` belongs
// to, then the plugins' Shot_Hit when `by` is shaped. A wearing shot
// (Wears_Down) takes no hits. It gives no more than it has left, wears down
// by what the hit dealt, shrinking, and once spent is destroyed, as the hit
// back would have destroyed it.
@(private = "file")
shot_hit :: proc(s: ^sim.State, by, target: sim.Entity, damage: f32, time: i32) {
	if target.wear > 0 {
		return
	}
	if by.wear <= 0 {
		dealt := entity_hit(s, target, damage, by.owner_player, time)
		if by.shaped_by != 0 {
			sim.shot_hit_run(s, by, target, dealt, time)
		}
		return
	}
	dealt := entity_hit(s, target, min(damage, by.wear), by.owner_player, time)
	sim.shot_hit_run(s, by, target, dealt, time)
	by.wear -= dealt
	if by.wear <= stats.WEAR_SPENT {
		lifecycle.entity_destroy(s, by, target.owner_player, time)
		return
	}
	by.size = stats.wear_size(s, by, by.wear)
}

// G_Player::Score_Adjust. `flat` bonuses bypass the multiplier and reset the
// extra-life step.
player_score :: proc(s: ^sim.State, p: sim.Player, n: i32, flat: bool) {
	if !p.active {
		return
	}
	v := flat ? n : n * p.multiplier
	score := p.score + v
	if n > 0 {
		step := sim.trunc_i32(s.defs.perm_floats[0xb6])
		if flat {
			p.life_step = step + score
		} else if p.next_life_score < score {
			player_add_life(s, p, true)
			p.next_life_score += sim.player_def(s, p).life_additional_required_score
			p.next_life_score += p.life_step
			p.life_step += step
		}
	}
	p.score = score
}

// G_Player::Lives_Add.
player_add_life :: proc(s: ^sim.State, p: sim.Player, announce: bool) {
	if !p.active {
		return
	}
	d := sim.player_def(s, p)
	n := p.lives + 1
	if d.life_max_num > 0 && d.life_max_num < n {
		n = d.life_max_num
	}
	if p.lives < n {
		if d.life_spawn != sim.NONE && announce {
			lifecycle.spawn_at(s, d.life_spawn, p.loc, p.number)
		}
		p.lives = n
	}
}
