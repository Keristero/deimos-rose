package sim

// What happens to a player that is hit: shields, the warning and hit spawns,
// death, and picking things up.
//
// Shields and money are stored plainly here; the original offsets them by
// constants (shields by 0x4eca70's value, money by 0xb2cce, lives by
// 0x1524dcef, score by 0x5532a3e) as light anti-tampering.

// G_Player::Shields_Reset.
player_shields_reset :: proc "contextless" (s: ^State, p: ^Player, full: bool) {
	if p.active && full {
		p.shields = f32(player_def(s, p).default_shield_percentage)
	} else if !p.active {
		p.shields = 0
	}
	p.hit_time = 0
	p.hit_spawn_time = 0
	p.shield_warned = false
}

// G_Player::Shields_IncreasePercentage.
player_shields_add :: proc "contextless" (s: ^State, p: ^Player, pct: f32) {
	if !p.active || pct == 0 {
		return
	}
	v := p.shields + pct
	if v > 100 {
		v = 100
	} else if v < 0 {
		v = 0
	}
	p.shields = v
}

// G_Player::Hit.
player_hit :: proc(s: ^State, p: ^Player, damage: f32, time: i32) {
	d := player_def(s, p)
	if p.state != .Playing || p.hit_time + d.shield_hit_delay > time {
		return
	}
	p.hit_time = time
	if !p.invulnerable {
		loss := f32(d.shield_base_hit_percentage) * damage
		if loss > 0 {
			p.defence_spawned = true // this[0xcc]: took damage this level
		}
		p.shields -= loss
	}
	if p.shields < 0 {
		player_destroy(s, p, time)
		return
	}
	p.glowing = true // Glow_Start with the definition's hit colour
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
player_destroy :: proc(s: ^State, p: ^Player, time: i32) {
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
player_multiplier_advance :: proc(s: ^State, p: ^Player) {
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
player_multiplier_spawn :: proc(s: ^State, p: ^Player) {
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
player_collect :: proc(s: ^State, p: ^Player, e: ^Entity) -> bool {
	u := unit_of(s, e)
	switch u.pickup_type {
	case res_id("air "), res_id("grnd"):
		// Weapon pickups are ignored while invulnerable.
		if p.invulnerable {
			return false
		}
		unported(s, 0x41c1e0) // weapon pickup: ChangeWeapon
	case res_id("spec"):
		unported(s, 0x41c220) // special weapon pickup
	case res_id("shie"):
		player_shields_add(s, p, f32(u.pickup_value))
	case res_id("exli"):
		player_add_life(s, p, true)
	case res_id("coin"):
		if u.pickup_value != 0 {
			p.money += u.pickup_value
			p.glowing = true
		}
	case res_id("mult"):
		player_multiplier_advance(s, p)
	}
	return true
}
