package player_system

// G_Player: set-up, the level-start reset, the entry sequence (state 2 ->
// Priv_Appear -> state 4), and the stages of G_Player::Process, run for one
// player at a time.

import "dr:sim"
import "dr:sim/lifecycle"
import "dr:sim/stats"
import "dr:sim/systems/background_system"
import "dr:sim/systems/collision_system"
import "dr:sim/systems/weapon_system"

// G_Player::SetUpAtNewGameStart (the parts that affect play).
player_setup :: proc (s: ^sim.State, p: sim.Player, number: i32, game_type: sim.Game_Type) {
	sim.object_defaults(p.obj)
	p.number = number
	p.game_type = game_type
	p.def = sim.player_def_index(s.defs, s.defs.perm_objects[number])
	// In a single-player game only player 1 takes part.
	p.active = game_type != .Single || number == 0
	if p.active {
		// G_Player::Lives_ResetAtNewGameStart; SetUpAtNewGameStart passes
		// "starting at level 1" for the initial-lives choice.
		d := sim.player_def(s, p)
		p.lives = sim.single(s, sim.Level_Info).number == 1 ? d.life_num_initial : 1
		p.next_life_score = d.life_initial_required_score
	}
	p.life_step = 0
	p.score = 0
	p.multiplier = 1
	p.multiplier_entity = -1
	p.calm = 0
	collision_system.player_shields_reset(s, p, true)
	weapon_system.weapons_new_game(s, p.weapons, number, sim.single(s, sim.Clock).time, sim.single(s, sim.Level_Info).number)
	p.speed = sim.player_def(s, p).active_default_max_speed
	if p.active {
		p.state, p.state_time = .Entering, sim.single(s, sim.Clock).time
		p.inputs = {}
	} else {
		p.state, p.state_time = .Gone, sim.single(s, sim.Clock).time
	}
}

// G_Player::Priv_SetSpriteFaceAccordingToAirWeapon.
player_sprite_from_weapon :: proc "contextless" (s: ^sim.State, p: sim.Player) {
	w := sim.weapon_def(s, weapon_system.air_weapon_shown(p.weapons))
	p.sprite = p.number == 0 ? w.player1_appearance_face : w.player2_appearance_face
	p.dims_dirty = true
}

// G_Player::Priv_ResetSpriteInfo.
player_reset_sprite :: proc "contextless" (s: ^sim.State, p: sim.Player) {
	player_sprite_from_weapon(s, p)
	p.frame = 0
	p.frame_time = 0
	p.draw_layer = {'p', 'l', 'a', 'y'}
}

// G_Player::ResetAtLevelStart.
player_level_reset :: proc (s: ^sim.State, p: sim.Player, time: i32) {
	if !p.active {
		return
	}
	p.defence_spawned = false
	weapon_system.weapons_appear(s, p.weapons, true)
	p.appeared = false
	lifecycle.glow_stop(p.obj) // Glow_Stop
	p.money = 0       // Money_Reset
	p.counter = {fade = 0x20} // MoneyCounter_Reset: hidden until it fades in
	collision_system.player_shields_reset(s, p, true)
	p.calm = 0
	collision_system.overload_clear(p)
	player_reset_sprite(s, p)
	lifecycle.calculate_dimensions(s, p.obj)
	player_reset_position(s, p)
	p.state, p.state_time = .Entering, time
	p.visibility = s.defs.perm_floats[sim.PF_PLAYER_APPEARS_INITIAL]
	p.visibility_target = s.defs.perm_floats[sim.PF_PLAYER_APPEARS_REQUIRED]
	p.visibility_delta = s.defs.perm_floats[sim.PF_PLAYER_APPEARS_DELTA]
	// Drawn even when the result is unused: the registration nag timer is
	// only armed for an unregistered player 1, but the draw always happens.
	nag := sim.roll_int(s, 400, 2000, 0x43103a)
	if p.number == 0 {
		p.nag_time = nag + time
	}
}

// G_Player::Priv_ResetPosition.
player_reset_position :: proc "contextless" (s: ^sim.State, p: sim.Player) {
	d := sim.player_def(s, p)
	if p.game_type == .Single {
		p.loc = {f32(d.entry_solo_start_x), f32(d.entry_solo_start_y)}
	} else {
		p.loc = {f32(d.entry_multi_start_x), f32(d.entry_multi_start_y)}
	}
	p.vel = {}
}

// G_Player::Priv_Appear.
player_appear :: proc(s: ^sim.State, p: sim.Player, time: i32) {
	if !p.active {
		return
	}
	player_reset_sprite(s, p)
	lifecycle.calculate_dimensions(s, p.obj)
	player_reset_position(s, p)
	// The overload state is cleared here, but not the shields and not
	// invulnerability: a player is invulnerable from the moment it is
	// destroyed until entry_invulnerability_time after it reappears, and
	// one that simply entered the level was never invulnerable at all.
	collision_system.overload_clear(p)
	p.calm = 0
	p.crosshair_reach = 0
	p.appeared = true
	p.state, p.state_time = .Playing, time
	p.visibility = s.defs.perm_floats[sim.PF_PLAYER_APPEARS_INITIAL]
	p.visibility_target = s.defs.perm_floats[sim.PF_PLAYER_APPEARS_REQUIRED]
	p.visibility_delta = s.defs.perm_floats[sim.PF_PLAYER_APPEARS_DELTA]
	d := sim.player_def(s, p)
	if d.entry_spawn != sim.NONE {
		lifecycle.spawn_at(s, d.entry_spawn, p.loc, p.number)
	}
	// Priv_Multiplier_SpawnForCurrentMultiplier, at the end of Priv_Appear
	// (0x4351d0). Only a death (G_Player::Destroy) or a new game resets the
	// multiplier, not ResetAtLevelStart, so a player entering a new level
	// still holds the last one's x2..x10 and needs its icon back: eg_reset
	// disposed it. After a death the multiplier is 1 and nothing spawns.
	collision_system.player_multiplier_spawn(s, p)
	weapon_system.weapons_appear(s, p.weapons, false)
}

// G_Player::Priv_ProcessState.
player_process_state :: proc(s: ^sim.State, p: sim.Player, time: i32) {
	if !p.active {
		return
	}
	d := sim.player_def(s, p)
	#partial switch p.state {
	case .Gone:
		if d.game_over_time + p.state_time < time {
			p.active = false
		}
	case .Entering:
		if d.entry_initial_delay + p.state_time < time {
			player_appear(s, p, time)
		}
	case .Dying:
		// The last life lingers longer before the game is over.
		wait := p.lives == 1 ? d.final_dying_time : d.dying_time
		if wait + p.state_time >= time {
			break
		}
		// A life is only spent once player 1 has actually been in play.
		if sim.single(s, sim.Game_Status).player1_seen_playing && p.active {
			p.lives = max(p.lives - 1, 0)
		}
		if p.lives <= 0 {
			p.state, p.state_time = .Gone, time
			break
		}
		player_appear(s, p, time)
		collision_system.player_shields_reset(s, p, true)
	case .Playing:
		// Entry invulnerability wears off; the kind granted at the end of
		// a level does not.
		if p.invulnerable && !sim.single(s, sim.Level_Info).ending && !p.invulnerable_always &&
		   d.entry_invulnerability_time + p.state_time < time && p.active {
			p.invulnerable = false
		}
	}
}

// G_Player::Process, stage by stage (sim/core has their order). Only an active player
// is processed, and only one in play fires and moves.
player_process :: proc(s: ^sim.State, p: sim.Player, time: i32, input: sim.Buttons, film: ^sim.Film) {
	if !p.active {
		return
	}
	ps := sim.Player_Step{time = time, input = input, film = film}
	sim.run_player_stages(s, p, &ps)
}

// The defence bonus, before Priv_ProcessState: once the level is ending
// (DAT_004e4855), a player who took no damage this level (this[0xcc] still
// clear) gets the "Notice - Defence Bonus" at their ship and level * perm
// float 0xb8 points. Setting the flag makes it once only.
defence_bonus_stage :: proc(s: ^sim.State, p: sim.Player, ps: ^sim.Player_Step) -> bool {
	if sim.single(s, sim.Level_Info).ending && !p.defence_spawned {
		p.defence_spawned = true
		if d := sim.player_def(s, p); d.active_defence_bonus_object != sim.NONE {
			lifecycle.spawn_at(s, d.active_defence_bonus_object, p.loc, p.number) // this+0xc2
		}
		collision_system.player_score(s, p, sim.single(s, sim.Level_Info).number * sim.trunc_i32(s.defs.perm_floats[0xb8]), false)
	}
	return true
}

player_state_stage :: proc(s: ^sim.State, p: sim.Player, ps: ^sim.Player_Step) -> bool {
	player_process_state(s, p, ps.time)
	return true
}

// Priv_GetInputs: only a player in play reads input, so a film is consumed
// one frame per step spent in state 4 -- not one per step.
read_input_stage :: proc(s: ^sim.State, p: sim.Player, ps: ^sim.Player_Step) -> bool {
	if p.state != .Playing {
		return true
	}
	p.inputs = {}
	if ps.film != nil {
		n := sim.single(s, sim.Film_Cursor).reads[p.number]
		if int(n) < len(ps.film.frames) {
			p.inputs = ps.film.frames[n][p.number]
		}
		// G_Film::GetInputs reads while cursor <= frames, so it is
		// called frames + 1 times; the last read yields nothing.
		if int(n) <= len(ps.film.frames) {
			sim.single(s, sim.Film_Cursor).reads[p.number] += 1
		}
		if p.number == 0 && s.draws != nil {
			s.draws.frame = u32(sim.single(s, sim.Film_Cursor).reads[0])
		}
	} else {
		// Pause is the port's (plugins/netplay), never the game's.
		p.inputs = ps.input - {.Pause}
	}
	return true
}

// Scale, overload glow, visibility, size and glow. A player out of play
// stops here.
player_look_stage :: proc(s: ^sim.State, p: sim.Player, ps: ^sim.Player_Step) -> bool {
	lifecycle.do_scaling(p.obj)
	collision_system.player_overload_process(s, p, ps.time)
	lifecycle.adjust_visibility_and_tinting(p.obj)
	if p.appeared && p.visibility == p.visibility_target {
		p.appeared = false
	}
	lifecycle.calculate_dimensions(s, p.obj)
	lifecycle.glow_process(p.obj)
	return p.state == .Playing
}

// The weapons fire, at full size only; holding a charge too long overloads.
fire_stage :: proc(s: ^sim.State, p: sim.Player, ps: ^sim.Player_Step) -> bool {
	if p.scale != 1 {
		return true
	}
	result, changed := weapon_system.weapons_process(s, p.weapons, p.loc,
		.Fire_Ground in p.inputs, .Fire_Air in p.inputs, .Change_Air in p.inputs, ps.time)
	if changed {
		player_sprite_from_weapon(s, p)
	}
	switch result {
	case .Overload:
		if p.state == .Playing && !sim.single(s, sim.Level_Info).ending && !p.overloaded {
			collision_system.player_overload_begin(s, p, ps.time)
		}
	case .Released:
		p.overloaded = false
		p.overload_rising = false
		p.overload_time, p.overload_interval, p.overload_warnings = 0, 0, 0
		p.colorise = false
		p.tint, p.tint_target, p.tint_delta = 0, 0, 0
		p.tint_color = 0x7fff
	case .None:
	}
	return true
}

// Where the original has nothing: counts the ship's calm, for plugins'
// stages placed before it.
calm_stage :: proc(s: ^sim.State, p: sim.Player, ps: ^sim.Player_Step) -> bool {
	if p.state == .Playing && p.calm < max(i32) {
		p.calm += 1
	}
	return true
}

player_move_stage :: proc(s: ^sim.State, p: sim.Player, ps: ^sim.Player_Step) -> bool {
	player_move(s, p, ps.time)
	return true
}

// The movement half of G_Player::Process: accelerate with the controls,
// decelerate without them, bank, move, clamp to the play area and steer the
// crosshair.
player_move :: proc(s: ^sim.State, p: sim.Player, time: i32) {
	d := sim.player_def(s, p)
	up, right := .Up in p.inputs, .Right in p.inputs
	down, left := .Down in p.inputs, .Left in p.inputs
	top, acc := p.speed, stats.player_acceleration(s, p, d.active_velocity_delta)

	if up {
		p.vel.y -= acc
		if p.vel.y < -top {
			p.vel.y = -top
		}
	}
	if down {
		p.vel.y += acc
		if top < p.vel.y {
			p.vel.y = top
		}
	}
	if left {
		p.vel.x -= acc
		if p.vel.x < -top {
			p.vel.x = -top
		}
	}
	if right {
		p.vel.x += acc
		if top < p.vel.x {
			p.vel.x = top
		}
	}
	coast :: proc "contextless" (v: ^f32, acc: f32) {
		if 0 < v^ {
			v^ -= acc
			if v^ < 0 {
				v^ = 0
			}
		}
		if v^ < 0 {
			v^ += acc
			if 0 < v^ {
				v^ = 0
			}
		}
	}
	if !left && !right {
		coast(&p.vel.x, acc)
	}
	if !up && !down {
		coast(&p.vel.y, acc)
	}

	// Banking: frame 0 is level, 1-3 bank left, 4-6 bank right. Frame changes
	// do not mark the dimensions dirty, so the player keeps its first size.
	if sim.trunc_i32(s.defs.perm_floats[0xa6]) + p.frame_time < time {
		p.frame_time = time
		LEVEL_OUT := [7]i32{0, 0, 1, 2, 0, 4, 5}
		BANK_RIGHT := [7]i32{4, 0, 1, 2, 5, 6, 6}
		BANK_LEFT := [7]i32{1, 2, 3, 3, 3, 4, 5}
		f := clamp(p.frame, 0, 6)
		if !left && !right {
			p.frame = LEVEL_OUT[f]
		} else if !left {
			p.frame = BANK_RIGHT[f]
		} else {
			p.frame = BANK_LEFT[f]
		}
	}

	p.loc += p.vel
	// Holding left or right slides the view sideways; left wins when both
	// are held, as in the original's nested test.
	if left {
		background_system.bgnd_adjust_side_scroll(s, false)
	} else if right {
		background_system.bgnd_adjust_side_scroll(s, true)
	}

	w, h := sim.view_width(s.defs), sim.view_height(s.defs)
	hx := p.half.x
	if p.loc.x - f32(hx) < -32 {
		p.loc.x = f32(hx - 32)
		p.vel.x = 0
	} else if !(f32(hx) + p.loc.x <= f32(w + 32)) {
		p.loc.x = f32(w - hx + 32)
		p.vel.x = 0
	}
	limit := sim.trunc_i32(s.defs.perm_floats[0xb7])
	hy := p.half.y
	at_bottom, at_top := false, false
	if f32(limit) <= p.loc.y - f32(hy) {
		if f32(h) < f32(hy) + p.loc.y {
			p.loc.y = f32(h - hy)
			p.vel.y = 0
			at_bottom = true
		}
	} else {
		p.loc.y = f32(limit + hy)
		p.vel.y = 0
		at_top = true
	}
	p.weapons.loc = p.loc

	if p.weapons.crosshair_shown {
		// A ground weapon firing backwards is pulled in by pushing against
		// the top of the screen instead of the bottom.
		backwards := stats.ground_fires_backwards(s, p.weapons)
		pull, pinned := down, at_bottom
		if backwards {
			pull, pinned = up, at_top
		}
		if !pull || !pinned {
			if 0 < p.crosshair_reach {
				p.crosshair_reach += sim.trunc_i32(s.defs.perm_floats[0xba])
				if p.crosshair_reach < 0 {
					p.crosshair_reach = 0
				}
			}
		} else {
			p.crosshair_reach += sim.trunc_i32(s.defs.perm_floats[0xb9])
			if mx := sim.trunc_i32(s.defs.perm_floats[0xbb]); mx < p.crosshair_reach {
				p.crosshair_reach = mx
			}
		}
		gw := sim.weapon_def(s, p.weapons.ground.weapon)
		c := p.weapons.crosshair
		loc := sim.Vec{f32(gw.crosshair_x_offset) + p.loc.x, f32(p.crosshair_reach) + f32(gw.crosshair_y_offset) + p.loc.y}
		half := lifecycle.halve(c.dims.y)
		if backwards {
			// Behind the ship at half the reach, kept on screen at the bottom.
			loc.y = p.loc.y - f32(p.crosshair_reach + gw.crosshair_y_offset) / 2
			if f32(h) < loc.y + f32(half) {
				loc.y = f32(h - half)
			}
		} else if loc.y - f32(half) < 0 {
			loc.y = f32(half)
		}
		c.loc = loc
	}
}

// G_ScoreBar_Process, which follows, is presentation.
players_system :: proc(s: ^sim.State, step: ^sim.Step) {
	for i in 0 ..< sim.MAX_PLAYERS {
		player_process(s, sim.player_at(s, i), sim.single(s, sim.Clock).time, step.input[i], step.film)
	}
}
