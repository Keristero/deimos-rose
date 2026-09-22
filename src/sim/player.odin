package sim

// G_Player. Ported so far: set-up, the level-start reset, the entry sequence
// (state 2 -> Priv_Appear -> state 4) and film input. Movement, weapons,
// shields and money are still to come; see docs/phase-4-sim.md.

Player_State :: enum i32 {
	None     = 0,
	Gone     = 1, // game over for this player
	Entering = 2,
	Dying    = 3,
	Playing  = 4, // only now does the player read input (Priv_GetInputs)
}

Player :: struct {
	using obj:     Game_Object,
	def:           i32,          // +0x8a index into Defs.players
	active:        bool,         // +0xb8 in the game at all
	appeared:      bool,         // +0xb9
	state:         Player_State, // +0xba
	state_time:    i32,          // +0xbe
	number:        i32,          // +0xc2 G_Game_PlayerNum
	game_type:     Game_Type,    // +0xc6
	lives:         i32,          // +0x8e (stored + 0x1524dcef in the original)
	next_life_score: i32,        // +0x92
	life_step:     i32,          // +0x96
	speed:         f32,          // +0x9a maximum speed
	score:         i32,          // +0xa6 (stored + 0x5532a3e in the original)
	multiplier:    i32,          // +0xaa
	frame_time:    i32,          // +0xce time of the last banking frame change
	defence_spawned: bool,       // +0xcc
	inputs:        Buttons,      // +0x1f6 this step's inputs
	crosshair_reach: i32,        // +0x205 how far the crosshair is pushed out
	overloaded:    bool,         // +0x209 air power-up overload in progress
	nag_time:      i32,          // +0x22b unregistered-copy nag timer
	weapons:       Weapon_Handler, // +0x235
}

player_def :: #force_inline proc "contextless" (s: ^State, p: ^Player) -> ^Player_Def {
	return &s.defs.players[p.def].def
}

// G_Player::SetUpAtNewGameStart (the parts that affect play).
player_setup :: proc (s: ^State, p: ^Player, number: i32, game_type: Game_Type) {
	object_defaults(&p.obj)
	p.number = number
	p.game_type = game_type
	p.def = player_def_index(s.defs, s.defs.perm_objects[number])
	// In a single-player game only player 1 takes part.
	p.active = game_type != .Single || number == 0
	if p.active {
		// G_Player::Lives_ResetAtNewGameStart; SetUpAtNewGameStart passes
		// "starting at level 1" for the initial-lives choice.
		d := player_def(s, p)
		p.lives = s.level_number == 1 ? d.life_num_initial : 1
		p.next_life_score = d.life_initial_required_score
	}
	p.life_step = 0
	p.score = 0
	p.multiplier = 1
	weapons_new_game(s, &p.weapons, number, s.time, s.level_number)
	p.speed = player_def(s, p).active_default_max_speed
	if p.active {
		p.state, p.state_time = .Entering, s.time
		p.inputs = {}
	} else {
		p.state, p.state_time = .Gone, s.time
	}
}

// G_Player::Priv_SetSpriteFaceAccordingToAirWeapon.
player_sprite_from_weapon :: proc "contextless" (s: ^State, p: ^Player) {
	w := weapon_def(s, air_weapon_shown(&p.weapons))
	p.sprite = p.number == 0 ? w.player1_appearance_face : w.player2_appearance_face
	p.dims_dirty = true
}

// G_Player::Priv_ResetSpriteInfo.
player_reset_sprite :: proc "contextless" (s: ^State, p: ^Player) {
	player_sprite_from_weapon(s, p)
	p.frame = 0
	p.frame_time = 0
	p.draw_layer = {'p', 'l', 'a', 'y'}
}

// G_Player::ResetAtLevelStart.
player_level_reset :: proc (s: ^State, p: ^Player, time: i32) {
	if !p.active {
		return
	}
	p.defence_spawned = false
	weapons_appear(s, &p.weapons, true)
	p.appeared = false
	player_reset_sprite(s, p)
	calculate_dimensions(s, &p.obj)
	player_reset_position(s, p)
	p.state, p.state_time = .Entering, time
	p.visibility = s.defs.perm_floats[PF_PLAYER_APPEARS_INITIAL]
	p.visibility_target = s.defs.perm_floats[PF_PLAYER_APPEARS_REQUIRED]
	p.visibility_delta = s.defs.perm_floats[PF_PLAYER_APPEARS_DELTA]
	// Drawn even when the result is unused: the registration nag timer is
	// only armed for an unregistered player 1, but the draw always happens.
	nag := random_int(&s.rng, 400, 2000, 0x43103a)
	if p.number == 0 {
		p.nag_time = nag + time
	}
}

// G_Player::Priv_ResetPosition.
player_reset_position :: proc "contextless" (s: ^State, p: ^Player) {
	d := player_def(s, p)
	if p.game_type == .Single {
		p.loc = {f32(d.entry_solo_start_x), f32(d.entry_solo_start_y)}
	} else {
		p.loc = {f32(d.entry_multi_start_x), f32(d.entry_multi_start_y)}
	}
	p.vel = {}
}

// G_Player::Priv_Appear.
player_appear :: proc(s: ^State, p: ^Player, time: i32) {
	if !p.active {
		return
	}
	player_reset_sprite(s, p)
	calculate_dimensions(s, &p.obj)
	player_reset_position(s, p)
	p.overloaded = false
	p.colorise = false
	p.tint, p.tint_target, p.tint_delta = 0, 0, 0
	p.tint_color = 0x7fff
	p.appeared = true
	p.state, p.state_time = .Playing, time
	p.visibility = s.defs.perm_floats[PF_PLAYER_APPEARS_INITIAL]
	p.visibility_target = s.defs.perm_floats[PF_PLAYER_APPEARS_REQUIRED]
	p.visibility_delta = s.defs.perm_floats[PF_PLAYER_APPEARS_DELTA]
	d := player_def(s, p)
	if d.entry_spawn != NONE {
		req := spawn_request(d.entry_spawn)
		req.loc = p.loc
		req.owner_player = p.number
		eg_request_spawn(s, req)
	}
	// Priv_Multiplier_SpawnForCurrentMultiplier: nothing to spawn until a
	// multiplier has been collected.
	weapons_appear(s, &p.weapons, false)
}

// G_Player::Priv_ProcessState.
player_process_state :: proc(s: ^State, p: ^Player, time: i32) {
	if !p.active {
		return
	}
	d := player_def(s, p)
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
		unported(s, 0x435620)
	}
}

// G_Player::Process: input and state so far.
player_process :: proc(s: ^State, p: ^Player, time: i32, input: Buttons, film: ^Film) {
	if !p.active {
		return
	}
	player_process_state(s, p, time)
	// Priv_GetInputs: only a player in play reads input, so a film is
	// consumed one frame per step spent in state 4 -- not one per step.
	if p.state == .Playing {
		p.inputs = {}
		if film != nil {
			n := s.film_cursor[p.number]
			if int(n) < len(film.frames) {
				p.inputs = film.frames[n][p.number]
			}
			// G_Film::GetInputs reads while cursor <= frames, so it is
			// called frames + 1 times; the last read yields nothing.
			if int(n) <= len(film.frames) {
				s.film_cursor[p.number] += 1
			}
			if p.number == 0 && s.rng.log != nil {
				s.rng.log.frame = u32(s.film_cursor[0])
			}
		} else {
			p.inputs = input
		}
	}
	do_scaling(&p.obj)
	if p.overloaded {
		unported(s, 0x431410) // G_Player::PowerupOverload_Process
	}
	adjust_visibility_and_tinting(&p.obj)
	if p.appeared && p.visibility == p.visibility_target {
		p.appeared = false
	}
	calculate_dimensions(s, &p.obj)
	if p.state != .Playing {
		return
	}
	if p.scale == 1 {
		result, changed := weapons_process(s, &p.weapons, p.loc,
			.Fire_Ground in p.inputs, .Fire_Air in p.inputs, .Change_Air in p.inputs, time)
		if changed {
			player_sprite_from_weapon(s, p)
		}
		switch result {
		case .Overload:
			if p.state == .Playing && !s.level_ending && !p.overloaded {
				p.overloaded = true
				unported(s, 0x432c90) // overload warning set-up
			}
		case .Released:
			p.overloaded = false
			p.colorise = false
			p.tint, p.tint_target, p.tint_delta = 0, 0, 0
			p.tint_color = 0x7fff
		case .None:
		}
	}
	player_move(s, p, time)
}

// The movement half of G_Player::Process: accelerate with the controls,
// decelerate without them, bank, move, clamp to the play area and steer the
// crosshair.
player_move :: proc(s: ^State, p: ^Player, time: i32) {
	d := player_def(s, p)
	up, right := .Up in p.inputs, .Right in p.inputs
	down, left := .Down in p.inputs, .Left in p.inputs
	top, acc := p.speed, d.active_velocity_delta

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
	if trunc_i32(s.defs.perm_floats[0xa6]) + p.frame_time < time {
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
	if left || right {
		// G_Bgnd_AdjustSideScroll: presentation (the background's sideways
		// parallax).
	}

	w, h := view_width(s.defs), view_height(s.defs)
	hx := p.half.x
	if p.loc.x - f32(hx) < -32 {
		p.loc.x = f32(hx - 32)
		p.vel.x = 0
	} else if !(f32(hx) + p.loc.x <= f32(w + 32)) {
		p.loc.x = f32(w - hx + 32)
		p.vel.x = 0
	}
	limit := trunc_i32(s.defs.perm_floats[0xb7])
	hy := p.half.y
	at_bottom := false
	if f32(limit) <= p.loc.y - f32(hy) {
		if f32(h) < f32(hy) + p.loc.y {
			p.loc.y = f32(h - hy)
			p.vel.y = 0
			at_bottom = true
		}
	} else {
		p.loc.y = f32(limit + hy)
		p.vel.y = 0
	}
	p.weapons.loc = p.loc

	if p.weapons.crosshair_shown {
		if !down || !at_bottom {
			if 0 < p.crosshair_reach {
				p.crosshair_reach += trunc_i32(s.defs.perm_floats[0xba])
				if p.crosshair_reach < 0 {
					p.crosshair_reach = 0
				}
			}
		} else {
			p.crosshair_reach += trunc_i32(s.defs.perm_floats[0xb9])
			if mx := trunc_i32(s.defs.perm_floats[0xbb]); mx < p.crosshair_reach {
				p.crosshair_reach = mx
			}
		}
		gw := weapon_def(s, p.weapons.ground.weapon)
		c := &p.weapons.crosshair
		loc := Vec{f32(gw.crosshair_x_offset) + p.loc.x, f32(p.crosshair_reach) + f32(gw.crosshair_y_offset) + p.loc.y}
		half := halve(c.dims.y)
		if loc.y - f32(half) < 0 {
			loc.y = f32(half)
		}
		c.loc = loc
	}
}

player_in_play :: #force_inline proc "contextless" (p: ^Player) -> bool {
	return p.state == .Playing
}
