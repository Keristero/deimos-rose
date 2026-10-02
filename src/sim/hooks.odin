package sim

// Hooks: the few places the core asks the plugins that are on for an
// answer mid-step, where a system of their own could not come in between.
// Each is registered from a registration step with the plugin it belongs
// to, and consulted only when that plugin runs in the session; with none
// on, every one answers as the original game does.

MAX_HOOKS :: 16

// A plugin's modifiers to the stats the core's mechanics read (sim/stats).
Stat_Provider :: struct {
	plugin: Plugin_ID,
	// What it adds to `stat` for `player`. `weapon` is the weapon the stat
	// is for, NONE for the ship. With `charge` the stat is for the weapon's
	// charge -- how it climbs, and the shots its release fires -- rather
	// than its shots: a provider may change either alone.
	total:  proc "contextless" (s: ^State, player: i32, stat: Stat, weapon: Res_ID, charge: bool) -> Stat_Total,
	// Whether it changes anything about `player`'s shots of `weapon` (of
	// its charge's release, with `charge`): they then carry the weapon
	// (Shaped), to be shaped after they spawn.
	shapes: proc "contextless" (s: ^State, player: i32, weapon: Res_ID, charge: bool) -> bool,
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

// A plugin's own way for a weapon to fire: new content whose shots are not
// the original's spawned projectiles. Which weapons it fires is the
// plugin's to say, from keys it registered on their definitions
// (def_keys.odin). Each part is optional; where one is nil, the original's
// firing stands.
//
// Unlike the other hooks it is not gated by the session's mods. How a
// weapon fires is part of that weapon's definition, and such a weapon only
// reaches a session through the plugin's own Weapon_Filter; a tool that
// flies the weapon alone (tools/dps) sees it fire as it does in play.
Weapon_Fire :: struct {
	plugin:  Plugin_ID,
	fires:   proc "contextless" (w: ^Weapon) -> bool,
	// With every press, after the weapon's own spawns and its wind-up.
	shot:    proc(s: ^State, h: ^Weapon_Handler, w: ^Weapon, at: Vec, time: i32),
	// Steps from a press to its shot. The weapon's own spawns come with
	// the press, `shot` when the wind-up is over, and the firing delay
	// counts from the shot. Nil or 0 fires on the press.
	windup:  proc "contextless" (w: ^Weapon) -> i32,
	// A charge let go all at once, whatever level it reached, in place of
	// one volley per level.
	release: proc(s: ^State, h: ^Weapon_Handler, w: ^Weapon, at: Vec, level: i32, time: i32),
	// One of a charge's volleys, in place of spawning the release unit.
	volley:  proc(s: ^State, h: ^Weapon_Handler, w: ^Weapon, at: Vec),
}

// What a plugin does when a player's shot that its weapon shapes (Shaped)
// hits: new content that follows from the hit, such as something left
// where it landed. Called after the hit, from collision_system, with the
// damage it dealt: 0 when the target's hit delay turned it away.
Shot_Hit :: struct {
	plugin: Plugin_ID,
	hit:    proc(s: ^State, shot, target: Entity, dealt: f32, time: i32),
}

@(private = "file")
stat_providers: Registry(Stat_Provider, MAX_HOOKS)
@(private = "file")
holds: Registry(Hold, MAX_HOOKS)
@(private = "file")
choosers: Registry(Weapon_Chooser, MAX_HOOKS)
@(private = "file")
filters: Registry(Weapon_Filter, MAX_HOOKS)
@(private = "file")
fires: Registry(Weapon_Fire, MAX_HOOKS)
@(private = "file")
shot_hits: Registry(Shot_Hit, MAX_HOOKS)

stat_provider_register :: proc(p: Stat_Provider) {
	registry_add(&stat_providers, p)
}

hold_register :: proc(h: Hold) {
	registry_add(&holds, h)
}

weapon_chooser_register :: proc(c: Weapon_Chooser) {
	registry_add(&choosers, c)
}

weapon_filter_register :: proc(f: Weapon_Filter) {
	registry_add(&filters, f)
}

weapon_fire_register :: proc(f: Weapon_Fire) {
	registry_add(&fires, f)
}

shot_hit_register :: proc(h: Shot_Hit) {
	registry_add(&shot_hits, h)
}

// A shaped shot's hit, for each plugin that is on.
shot_hit_run :: proc(s: ^State, shot, target: Entity, dealt: f32, time: i32) {
	for &h in registry_items(&shot_hits) {
		if mod_on(s, h.plugin) {
			h.hit(s, shot, target, dealt, time)
		}
	}
}

// How `w` fires, when a plugin fires it: the first registered that does.
weapon_fire :: proc "contextless" (w: ^Weapon) -> (^Weapon_Fire, bool) {
	for &f in registry_items(&fires) {
		if f.fires(w) {
			return &f, true
		}
	}
	return nil, false
}

// Every provider's contribution to `stat`, summed: percentages and extras
// add, and a switch is on if any turns it on.
stat_of :: proc "contextless" (s: ^State, player: i32, stat: Stat, weapon: Res_ID, charge := false) -> (t: Stat_Total) {
	for &p in registry_items(&stat_providers) {
		if !mod_on(s, p.plugin) {
			continue
		}
		v := p.total(s, player, stat, weapon, charge)
		t.percent += v.percent
		t.extra += v.extra
		t.enabled ||= v.enabled
	}
	return
}

// Whether any provider shapes `player`'s shots of `weapon`, or with
// `charge` the shots of its charge.
stat_shapes :: proc "contextless" (s: ^State, player: i32, weapon: Res_ID, charge := false) -> bool {
	for &p in registry_items(&stat_providers) {
		if mod_on(s, p.plugin) && p.shapes(s, player, weapon, charge) {
			return true
		}
	}
	return false
}

// Whether play stands still this step for a pause or a between-play screen:
// the presentation holds its own effects still to match.
session_frozen :: proc "contextless" (s: ^State) -> bool {
	for &h in registry_items(&holds) {
		if mod_on(s, h.plugin) && h.held(s) {
			return true
		}
	}
	return false
}

// The weapon chooser in this session, if any: the first registered that is
// on.
weapon_chooser :: proc "contextless" (s: ^State) -> (^Weapon_Chooser, bool) {
	for &c in registry_items(&choosers) {
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

// Whether a weapon can be chosen in this session: any of the original's, a
// plugin's own while that plugin is on, and any other once a filter lets it
// in.
weapon_allowed :: proc "contextless" (s: ^State, w: ^Weapon) -> bool {
	if !w.extra || (w.plugin != CORE && mod_on(s, w.plugin)) {
		return true
	}
	for &f in registry_items(&filters) {
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
	Volley_Delay,             // the gap between the volleys of one shot
	Extra_Projectiles,        // more lanes in each volley, continuing the spread
	Extra_Volley,             // more volleys per shot
	Accelerating_Projectiles, // shots start slow and speed up
	Initial_Projectile_Speed, // the speed shots leave the ship at
	Projectile_Lifetime,      // how long a shot flies, and so its range
	Side_Firing_Volley,       // each volley also fires to both sides
	Firing_Delay,             // the gap between shots
	Projectile_Damage,        // the damage each shot, and what it spawns, deals
	Random_Spread_Range,      // how far either side of its heading a shot may stray
	Shot_Width,               // how wide a shot cast as a line, not flown, is
	Ground_Charge,            // holding the ground weapon charges one heavier bomb, dropped on release
	Charge_Aim_Behind,        // while it is charged the crosshair swings round behind the ship
	Charge_Aim_Around,        // while it is charged the crosshair circles the ship
	Chains,                   // a shot cast as a line jumps from each target it kills to the nearest it has not hit
	Release_Ramp,             // a charge's release fires faster with each spawn it has fired
	Overcharge_Projectiles,   // a release fans out more lanes while its level is over the weapon's own max
	Shot_Scale,               // how large a flown shot is, and so what it reaches
	Wears_Down,               // a shot is not stopped by what it hits: it gives a store of damage, shrinking as it does
	Hit_Cloud,                // a shot's hit leaves a cloud that harms what lingers in it
	Cloud_Lifetime,           // how long such a cloud lingers
	Hits_Ground,              // an air shot also hits the ground targets it flies over
	Ground_Damage,            // how much of its damage such a shot deals them
}


Stat_Total :: struct {
	percent: i32, // increases minus decreases
	extra:   i32,
	enabled: bool,
}
