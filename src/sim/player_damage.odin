package sim

// What happens to a player that is hit: shields, the warning and hit spawns,
// death, and picking things up.
//
// Shields and money are stored plainly here; the original offsets them by
// constants (shields by 0x4eca70's value, money by 0xb2cce, lives by
// 0x1524dcef, score by 0x5532a3e) as light anti-tampering. The integer
// offsets change nothing, but the shields one does: see shields_set.

// The shields offset, the single-precision float at 0x4eca70.
@(private = "file") SHIELDS_OFFSET: f32 : 1324366

// G_Player::Shields_SetPercentage (0x431a30): `flds pct; fadds 0x4eca70;
// fstps this+0x9e`. The stored value is a float near 1.3 million, whose
// spacing is 1/8, so every percentage the original keeps is rounded to the
// nearest eighth. Shields_GetPercentage (`fsubs 0x4eca70`) takes the offset
// back off exactly. Whole numbers pass through unchanged; a hit's fractional
// loss does not. Adding and subtracting in f32 rounds the sum once, as the
// store does.
shields_set :: proc "contextless" (p: Player, pct: f32) {
	p.shields = (pct + SHIELDS_OFFSET) - SHIELDS_OFFSET
}

// G_Player::Shields_Reset.
player_shields_reset :: proc "contextless" (s: ^State, p: Player, full: bool) {
	if p.active && full {
		shields_set(p, f32(player_def(s, p).default_shield_percentage))
	} else if !p.active {
		shields_set(p, 0)
	}
	p.hit_time = 0
	p.hit_spawn_time = 0
	p.shield_warned = false
}

// G_Player::Shields_IncreasePercentage.
player_shields_add :: proc "contextless" (s: ^State, p: Player, pct: f32) {
	if !p.active || pct == 0 {
		return
	}
	v := p.shields + pct
	if v > 100 {
		v = 100
	} else if v < 0 {
		v = 0
	}
	shields_set(p, v)
}

// G_Player::Hit.
player_hit :: proc(s: ^State, p: Player, damage: f32, time: i32) {
	d := player_def(s, p)
	if p.state != .Playing || p.hit_time + d.shield_hit_delay > time {
		return
	}
	p.hit_time = time
	if !p.invulnerable {
		loss := f32(d.shield_base_hit_percentage) * damage
		if loss > 0 {
			p.defence_spawned = true // this[0xcc]: took damage this level
			player_regen_interrupt(p)
		}
		// G_Player::Hit (0x431688): the loss and the new value are each
		// stored as a float (fstps) before Shields_SetPercentage.
		shields_set(p, p.shields - loss)
	}
	if p.shields < 0 {
		player_destroy(s, p, time)
		return
	}
	glow_start(p.obj, color_1555(d.hit_glow_color), d.hit_glow_speed, false)
	if damage <= 0 {
		return
	}
	if d.active_spawn_on_hit != NONE &&
	   trunc_i32(s.defs.perm_floats[0xa2]) + p.hit_spawn_time <= time {
		p.hit_spawn_time = time
		req := spawn_request(d.active_spawn_on_hit)
		req.loc = p.loc
		req.owner_player = p.number
		eg_request_spawn(s, req)
	}
	if !p.shield_warned && p.shields <= f32(d.shield_warning_percentage) {
		if d.active_shield_warning_object != NONE {
			req := spawn_request(d.active_shield_warning_object)
			req.loc = p.loc
			req.owner_player = p.number
			eg_request_spawn(s, req)
		}
		p.shield_warned = true
	}
}

// G_Player::Destroy: the player dies, spilling its money as coins.
player_destroy :: proc(s: ^State, p: Player, time: i32) {
	dispose_players_children(s, p.number)
	d := player_def(s, p)
	if d.death_spawn != NONE {
		req := spawn_request(d.death_spawn)
		req.loc = p.loc
		req.owner_player = p.number
		eg_request_spawn(s, req)
	}
	p.hit_time = 0
	p.hit_spawn_time = 0
	p.shield_warned = false
	// Coins, largest denomination first: perm objects 2 (50), 3 (10),
	// 4 (5) and 5 (1).
	money := p.money
	for value, i in ([4]i32{50, 10, 5, 1}) {
		unit := s.defs.perm_objects[2 + i]
		for money >= value {
			money -= value
			if unit != NONE {
				req := spawn_request(unit)
				req.loc = p.loc
				eg_request_spawn(s, req)
			}
		}
	}
	p.money = 0
	p.state, p.state_time = .Dying, time
	if p.active {
		p.invulnerable = true
	}
	if p.multiplier != 1 {
		dispose_entity_number(s, p.multiplier_entity)
		p.multiplier = 1
	}
}

// G_Player::Multiplier_Advance: 1, 2, 3, 4, 5, then 10.
player_multiplier_advance :: proc(s: ^State, p: Player) {
	if p.state != .Playing {
		return
	}
	switch p.multiplier {
	case 1, 2, 3, 4:
		p.multiplier += 1
	case 5:
		p.multiplier = 10
	case:
		return
	}
	player_multiplier_spawn(s, p)
}

// G_Player::Priv_Multiplier_SpawnForCurrentMultiplier: the icon that shows
// the current multiplier (perm objects 0x23..0x27).
player_multiplier_spawn :: proc(s: ^State, p: Player) {
	if p.state != .Playing {
		return
	}
	idx := -1
	switch p.multiplier {
	case 2:
		idx = 0x23
	case 3:
		idx = 0x24
	case 4:
		idx = 0x25
	case 5:
		idx = 0x26
	case 10:
		idx = 0x27
	}
	if idx < 0 {
		return
	}
	unit := s.defs.perm_objects[idx]
	if unit == NONE {
		return
	}
	dispose_entity_number(s, p.multiplier_entity)
	req := spawn_request(unit)
	req.loc = p.loc
	req.owner_player = p.number
	r := eg_request_spawn(s, req)
	p.multiplier_entity = r.number
}

// G_EG_DisposeByUniqueEntityNum.
dispose_entity_number :: proc "contextless" (s: ^State, number: i32) {
	w := &s.world
	g := w.active.head
	for g != NO_LINK {
		i := w.groups[g].entities.head
		for i != NO_LINK {
			e := entity_at(s, i)
			if e.number == number {
				e.deleted = true
				e.target_player = -1
				return
			}
			i = w.entity_links[i].next
		}
		g = w.group_links[g].next
	}
}

// G_EG_DisposePlayersChildren.
dispose_players_children :: proc "contextless" (s: ^State, player: i32) {
	w := &s.world
	g := w.active.head
	for g != NO_LINK {
		i := w.groups[g].entities.head
		for i != NO_LINK {
			e := entity_at(s, i)
			if e.owner_player == player && state_of(s, e).can_be_deleted_on_owner_deletion {
				e.deleted = true
				e.target_player = -1
			}
			i = w.entity_links[i].next
		}
		g = w.group_links[g].next
	}
}

// FUN_0041c1b0: a player touches a pickup. Returns whether the pickup is
// consumed (the caller then destroys it).
player_collect :: proc(s: ^State, p: Player, e: ^Entity) -> bool {
	u := unit_of(s, e)
	switch u.pickup_type {
	case res_id("air "), res_id("grnd"):
		// An invulnerable player leaves a weapon pickup where it is.
		// Collecting one only destroys it: the weapon itself changes when
		// the player presses Change_Air, in G_WeaponHandler::Process.
		if p.invulnerable {
			return false
		}
	case res_id("spec"):
		// Collected and destroyed, with no other effect (FUN_0041c1b0).
	case res_id("shie"):
		player_shields_add(s, p, f32(u.pickup_value))
	case res_id("exli"):
		player_add_life(s, p, true)
	case res_id("coin"):
		if u.pickup_value != 0 {
			p.money += u.pickup_value
			glow_start(p.obj, 0x7fff, 6, false) // a white flash (FUN_0041c1b0)
		}
	case res_id("mult"):
		player_multiplier_advance(s, p)
	}
	return true
}

// G_Player::PowerupOverload_Process: while an air power-up is overloaded the
// player flashes and a warning sounds at a shrinking interval; after
// `powerupOverload_NumWarnings` warnings the player is destroyed.
player_overload_process :: proc(s: ^State, p: Player, time: i32) {
	if p.state != .Playing {
		if p.overloaded {
			overload_clear(p)
		}
		return
	}
	if !p.overloaded {
		return
	}
	if single(s, Level_Info).ending {
		overload_clear(p)
		return
	}
	d := player_def(s, p)
	if !p.overload_rising {
		p.tint -= d.powerup_overload_warning_fade_percent
		if p.tint <= 0 {
			p.tint = 0
			p.overload_rising = true
		}
	} else if p.overload_time + p.overload_interval < time {
		p.overload_time = time
		p.tint += 100
		if 100 <= p.tint {
			p.tint = 100
			p.overload_rising = false
			p.overload_interval -= 1
			if p.overload_interval < d.powerup_overload_minimum_time_between_warnings {
				p.overload_interval = d.powerup_overload_minimum_time_between_warnings
			}
			p.overload_warnings += 1
			if p.overload_warnings == d.powerup_overload_num_warnings {
				player_destroy(s, p, time)
				return
			}
			sound_play(s, Sound_Settings {
				id         = d.powerup_overload_sound,
				min_volume = d.powerup_overload_sound_min_volume,
				max_volume = d.powerup_overload_sound_max_volume,
				priority   = d.powerup_overload_sound_priority,
				min_pitch  = d.powerup_overload_sound_min_pitch,
				max_pitch  = d.powerup_overload_sound_max_pitch,
			}, true)
		}
	}
	p.colorise = false
	p.tint_target = p.tint
	p.tint_delta = 0
	p.tint_color = color_1555(d.powerup_overload_hilite)
}

// G_Player::PowerupOverload_Reset.
overload_clear :: proc "contextless" (p: Player) {
	p.overloaded = false
	p.overload_rising = false
	p.overload_time = 0
	p.overload_interval = 0
	p.overload_warnings = 0
	p.colorise = false
	p.tint, p.tint_target, p.tint_delta = 0, 0, 0
	p.tint_color = 0x7fff
}

// The overload start in G_Player::Process, when the weapon handler reports it.
player_overload_begin :: proc "contextless" (s: ^State, p: Player, time: i32) {
	d := player_def(s, p)
	p.overloaded = true
	p.overload_rising = true
	p.overload_time = time
	p.overload_interval = d.powerup_overload_initial_time_between_warnings
	p.overload_warnings = 0
	p.tint_color = color_1555(d.powerup_overload_hilite)
}
