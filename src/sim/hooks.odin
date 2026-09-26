package sim

// Hooks: the few places the core asks the plugins that are on for an
// answer mid-step, where a system of their own could not come in between.
// Each is registered from an @(init) procedure with the plugin it belongs
// to, and consulted only when that plugin runs in the session; with none
// on, every one answers as the original game does.

MAX_HOOKS :: 16

// A plugin's modifiers to the stats the core's mechanics read (sim/stats).
Stat_Provider :: struct {
	plugin: Plugin_ID,
	// What it adds to `stat` for `player`. `weapon` is the weapon the stat
	// is for, NONE for the ship.
	total:  proc "contextless" (s: ^State, player: i32, stat: Stat, weapon: Res_ID) -> Stat_Total,
	// Whether it changes anything about `player`'s shots of `weapon`: they
	// then carry the weapon (Shaped), to be shaped after they spawn.
	shapes: proc "contextless" (s: ^State, player: i32, weapon: Res_ID) -> bool,
}

// Something that holds play still: a pause, a screen between levels.
Hold :: struct {
	plugin: Plugin_ID,
	held:   proc "contextless" (s: ^State) -> bool,
}

// A plugin's own choice of air weapons, in place of the original's: which
// one a session starts with, and which Change_Air moves on to. A player
// under one keeps the weapon they fly from level to level.
Weapon_Chooser :: struct {
	plugin:   Plugin_ID,
	new_game: proc "contextless" (s: ^State, h: Weapons, level: i32) -> i32,
	next:     proc "contextless" (s: ^State, h: Weapons, current: i32) -> i32,
}

// Lets new content's weapons (Weapon.extra), which the original's rules
// never see, be chosen.
Weapon_Filter :: struct {
	plugin: Plugin_ID,
	allows: proc "contextless" (w: ^Weapon) -> bool,
}

@(private = "file")
Hooks :: struct {
	stats:         [MAX_HOOKS]Stat_Provider,
	stat_count:    int,
	holds:         [MAX_HOOKS]Hold,
	hold_count:    int,
	choosers:      [MAX_HOOKS]Weapon_Chooser,
	chooser_count: int,
	filters:       [MAX_HOOKS]Weapon_Filter,
	filter_count:  int,
}

@(private = "file")
hooks: Hooks

stat_provider_register :: proc(p: Stat_Provider) {
	assert(hooks.stat_count < MAX_HOOKS, "sim: too many stat providers")
	hooks.stats[hooks.stat_count] = p
	hooks.stat_count += 1
}

hold_register :: proc(h: Hold) {
	assert(hooks.hold_count < MAX_HOOKS, "sim: too many holds")
	hooks.holds[hooks.hold_count] = h
	hooks.hold_count += 1
}

weapon_chooser_register :: proc(c: Weapon_Chooser) {
	assert(hooks.chooser_count < MAX_HOOKS, "sim: too many weapon choosers")
	hooks.choosers[hooks.chooser_count] = c
	hooks.chooser_count += 1
}

weapon_filter_register :: proc(f: Weapon_Filter) {
	assert(hooks.filter_count < MAX_HOOKS, "sim: too many weapon filters")
	hooks.filters[hooks.filter_count] = f
	hooks.filter_count += 1
}

// Every provider's contribution to `stat`, summed: percentages and extras
// add, and a switch is on if any turns it on.
stat_of :: proc "contextless" (s: ^State, player: i32, stat: Stat, weapon: Res_ID) -> (t: Stat_Total) {
	for &p in hooks.stats[:hooks.stat_count] {
		if !mod_on(s, p.plugin) {
			continue
		}
		v := p.total(s, player, stat, weapon)
		t.percent += v.percent
		t.extra += v.extra
		t.enabled ||= v.enabled
	}
	return
}

// Whether any provider shapes `player`'s shots of `weapon`.
stat_shapes :: proc "contextless" (s: ^State, player: i32, weapon: Res_ID) -> bool {
	for &p in hooks.stats[:hooks.stat_count] {
		if mod_on(s, p.plugin) && p.shapes(s, player, weapon) {
			return true
		}
	}
	return false
}

// Whether play stands still this step for a pause or a between-play screen:
// the presentation holds its own effects still to match.
session_frozen :: proc "contextless" (s: ^State) -> bool {
	for &h in hooks.holds[:hooks.hold_count] {
		if mod_on(s, h.plugin) && h.held(s) {
			return true
		}
	}
	return false
}

// The weapon chooser in this session, if any: the first registered that is
// on.
weapon_chooser :: proc "contextless" (s: ^State) -> (^Weapon_Chooser, bool) {
	for &c in hooks.choosers[:hooks.chooser_count] {
		if mod_on(s, c.plugin) {
			return &c, true
		}
	}
	return nil, false
}

// Whether players keep the air weapon they fly from level to level, rather
// than taking up each level's new one: under a weapon chooser.
weapons_kept :: proc "contextless" (s: ^State) -> bool {
	_, ok := weapon_chooser(s)
	return ok
}

// Whether a weapon can be chosen in this session: any of the original's,
// and new content's once a plugin lets it in.
weapon_allowed :: proc "contextless" (s: ^State, w: ^Weapon) -> bool {
	if !w.extra {
		return true
	}
	for &f in hooks.filters[:hooks.filter_count] {
		if mod_on(s, f.plugin) && f.allows(w) {
			return true
		}
	}
	return false
}

Stat :: enum u8 {
	Maneuverability,          // the ship's acceleration, active_velocity_delta
	Risky_Reward,             // a 2000-point pickup somewhere on screen every RISKY_REWARD_SECONDS
	Auto_Charge_Air_To_Air,   // the air power-up charges on its own; a tap releases it, holding autofires
	Prevent_Overheat,         // a charged power-up never overloads
	Charge_Rate,              // how fast the power level climbs while charging
	Overheat_Delay,           // how long a charge is held before it overloads
	Maximum_Charge,           // the highest power level a charge reaches
	Shield_Regenerates,       // shields refill on their own
	Recharge_Delay,           // seconds without damage before they start to
	Shield_Regen_Rate,        // percentage points per second they refill by
	Fires_Backwards,          // the ground weapon drops behind the ship, at half the reach
	Volley_Delay,             // the gap between the volleys of one shot
	Extra_Projectiles,        // more lanes in each volley, continuing the spread
	Extra_Volley,             // more volleys per shot
	Accelerating_Projectiles, // shots start slow and speed up
	Initial_Projectile_Speed, // the speed shots leave the ship at
	Projectile_Lifetime,      // how long a shot flies, and so its range
	Side_Firing_Volley,       // each volley also fires to both sides
	Firing_Delay,             // the gap between shots
	Projectile_Damage,        // the damage each shot, and what it spawns, deals
}


Stat_Total :: struct {
	percent: i32, // increases minus decreases
	extra:   i32,
	enabled: bool,
}
