package sim

// The players' components. Each player is an entity (2..3) holding a
// Game_Object, Ship, Purse, Hull, Overload and Weapon_Handler; each ground
// crosshair is its own entity (4..5) with a Game_Object and a Crosshair.
// Player and Weapons are views of one player's components, found once and
// passed by value. player_system, weapon_system and collision_system act on
// them.
//
// Weapons are indices into Defs.weapons (-1 for none) where the original
// holds G_WepDef pointers. Offsets are relative to G_Player, and the weapon
// handler's to the handler, which sits at G_Player + 0x235.

Player_State :: enum i32 {
	None     = 0,
	Gone     = 1, // game over for this player
	Entering = 2,
	Dying    = 3,
	Playing  = 4, // only now does the player read input (Priv_GetInputs)
}

// A player is its ship entity, with these components, plus its crosshair
// (a second entity; see Weapons). Offsets are into the original's G_Player.
Ship :: struct {
	def:           i32,          // +0x8a index into Defs.players
	active:        bool,         // +0xb8 in the game at all
	appeared:      bool,         // +0xb9
	state:         Player_State, // +0xba
	state_time:    i32,          // +0xbe
	number:        i32,          // +0xc2 G_Game_PlayerNum
	game_type:     Game_Type,    // +0xc6
	speed:         f32,          // +0x9a maximum speed
	invulnerable:  bool,         // +0xca
	// +0xcb: invulnerability that does not wear off. Only the console
	// cheat in FUN_00421970 sets it; the end of a level does not.
	invulnerable_always: bool,
	hit_time:      i32,          // +0x1fd
	hit_spawn_time: i32,         // +0x201
	frame_time:    i32,          // +0xce time of the last banking frame change
	defence_spawned: bool,       // +0xcc
	inputs:        Buttons,      // +0x1f6 this step's inputs
	crosshair_reach: i32,        // +0x205 how far the crosshair is pushed out
	nag_time:      i32,          // +0x22b unregistered-copy nag timer
}

// Lives, score and money.
Purse :: struct {
	lives:         i32,          // +0x8e (stored + 0x1524dcef in the original)
	next_life_score: i32,        // +0x92
	life_step:     i32,          // +0x96
	money:         i32,          // +0xa2
	score:         i32,          // +0xa6 (stored + 0x5532a3e in the original)
	multiplier:    i32,          // +0xaa
	multiplier_entity: i32,      // +0xae the icon's unique entity number
	counter:       Money_Counter, // +0xd2 the end-of-level money readout
}

Hull :: struct {
	shields:       f32,          // +0x9e as a percentage
	shield_warned: bool,         // +0xcd
	// Not the original's, which never reads it: steps in play since the ship
	// last lost shields, appeared or started a level, for plugins that wait
	// on it (shield regeneration). Saturates rather than wrapping to zero.
	calm:          i32,
}

// The air power-up overload.
Overload :: struct {
	overloaded:    bool,         // +0x209 overload in progress
	overload_rising: bool,       // +0x20a
	overload_time: i32,          // +0x20f
	overload_interval: i32,      // +0x213
	overload_warnings: i32,      // +0x217
}

// One player's components, found once (player_at). Good for the step it
// was found in (D39).
Player :: struct {
	using obj:     ^Game_Object,
	using ship:    ^Ship,
	using purse:   ^Purse,
	using hull:    ^Hull,
	using surge:   ^Overload,
	weapons:       Weapons,
}

player_components :: proc "contextless" () -> Component_Mask {
	return {
		component_id(Game_Object),
		component_id(Ship),
		component_id(Purse),
		component_id(Hull),
		component_id(Overload),
		component_id(Weapon_Handler),
	}
}

// Both players, in order.
players_of :: proc "contextless" (s: ^State) -> (all: [MAX_PLAYERS]Player) {
	for &p, i in all {
		p = player_at(s, i)
	}
	return
}

player_at :: proc "contextless" (s: ^State, index: $I) -> Player {
	i := i32(index)
	id := player_entity(i)
	e := s.ecs
	return {
		obj      = get(e, id, Game_Object),
		ship     = get(e, id, Ship),
		purse    = get(e, id, Purse),
		hull     = get(e, id, Hull),
		surge    = get(e, id, Overload),
		weapons  = weapons_of(s, i),
	}
}

player_def :: #force_inline proc "contextless" (s: ^State, p: Player) -> ^Player_Def {
	return &s.defs.players[p.def].def
}

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
	// Not the original's; used only by stat providers (sim/stats).
	air_idle:        i32,  // steps fire-air has been let go, for Auto Charge
	volleys_left:    i32,  // extra volleys still owed by the last shot
	volley_pace:     i32,  // hundredths of a step towards the next one
	ground_pace:     i32,  // hundredths of a step towards the next bomb
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

players_in_play :: proc "contextless" (s: ^State) -> (n: i32) {
	for p in players_of(s) {
		if p.state == .Playing {
			n += 1
		}
	}
	return
}
