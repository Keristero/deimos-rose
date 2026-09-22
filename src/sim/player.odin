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
	defence_spawned: bool,       // +0xcc
	inputs:        Buttons,      // +0x1f6 this step's inputs
	nag_time:      i32,          // +0x22b unregistered-copy nag timer
}

player_def :: #force_inline proc "contextless" (s: ^State, p: ^Player) -> ^Player_Def {
	return &s.defs.players[p.def].def
}

// G_Player::SetUpAtNewGameStart (the parts that affect play).
player_setup :: proc "contextless" (s: ^State, p: ^Player, number: i32, game_type: Game_Type) {
	object_defaults(&p.obj)
	p.number = number
	p.game_type = game_type
	p.def = player_def_index(s.defs, s.defs.perm_objects[number])
	// In a single-player game only player 1 takes part.
	p.active = game_type != .Single || number == 0
	p.state = .None
}

// G_Player::ResetAtLevelStart.
player_level_reset :: proc "contextless" (s: ^State, p: ^Player, time: i32) {
	if !p.active {
		return
	}
	p.defence_spawned = false
	p.appeared = false
	p.dims_dirty = true
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
	player_reset_position(s, p)
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
	// Priv_Multiplier_SpawnForCurrentMultiplier and the weapon handler's
	// appearance set-up follow; neither draws at the first appearance.
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
}

player_in_play :: #force_inline proc "contextless" (p: ^Player) -> bool {
	return p.state == .Playing
}
