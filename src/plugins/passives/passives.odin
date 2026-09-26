package passives

// Passive upgrades: new content, not the original's. The design is
// notes/passive-upgrades-and-easy-mode.md; docs/passive-upgrades.md records
// how each entry was read.
//
// A passive has one to three levels, and each level lists modifiers to the
// core's stats (sim/stats), which this plugin provides. Within one
// passive only the level held counts, not the levels below it ((10,x,30) is
// 30 at level 3, not 40). An `x` (X below) leaves the value as the level
// below had it; a stat whose levels up to the one held are all x is not
// touched at all.
//
// The levels are a component on each player's entity (Passive_State), so
// rollback snapshots and the reconnect resync carry them. Nothing here
// gives a player a passive: easy mode's reward screen (plugins/easy_mode)
// does.

import "base:runtime"

// Imported for its registration: a dependency is always in the build.
import _ "dr:plugins/extra_prefs"
import _ "dr:sim/core"
import "dr:sim"
import "dr:sim/stats"
import "dr:sim/lifecycle"
import "dr:sim/systems/collision_system"

Res_ID :: sim.Res_ID
NONE :: sim.NONE
Stat :: sim.Stat
Stat_Total :: sim.Stat_Total

Passive :: enum u8 {
	Improved_Manoeuvring,
	Auto_Charge,
	Improved_Charge,
	Shield_Regen,
	Ground_Variant_1,
	Weapon_1,
	Weapon_2,
	Weapon_3,
	Weapon_4,
}

Mod_Kind :: enum u8 {
	Increase,
	Decrease,
	Extra,
	Enables,
}

MAX_PASSIVE_LEVELS :: 3

// The design's `x`: this level leaves the stat as the level below had it.
X :: min(i16)

Mod :: struct {
	stat: Stat,
	kind: Mod_Kind,
	at:   [MAX_PASSIVE_LEVELS]i16, // one per level; Enables is 1 for true
}

Passive_Def :: struct {
	levels: u8,
	// NONE for a ship passive. A weapon passive's modifiers apply to that
	// weapon's own shots alone, and it is only offered while the weapon can
	// be flown (see passive_available).
	weapon: Res_ID,
	mods:   []Mod,
}

// The weapons the design calls Weapon 1-4 and Ground Variant 1: the four
// air weapons in the order they unlock (aiic from level 1, aibg 2, airg 3,
// aipb 5), and the one ground weapon.
WEAPON_ION_CANNON :: Res_ID{'a', 'i', 'i', 'c'}
WEAPON_BACTA_GUN :: Res_ID{'a', 'i', 'b', 'g'}
WEAPON_REAR_GUN :: Res_ID{'a', 'i', 'r', 'g'}
WEAPON_PHOTON_BEAM :: Res_ID{'a', 'i', 'p', 'b'}
WEAPON_PLASMA_BOMB :: Res_ID{'p', 'l', 'b', 'o'}

PASSIVES := [Passive]Passive_Def {
	.Improved_Manoeuvring = {
		levels = 2,
		weapon = NONE,
		mods = {
			{.Maneuverability, .Increase, {20, 50, X}},
			{.Risky_Reward, .Enables, {X, 1, X}},
		},
	},
	.Auto_Charge = {
		levels = 2,
		weapon = NONE,
		mods = {
			{.Auto_Charge_Air_To_Air, .Enables, {1, X, X}},
			{.Prevent_Overheat, .Enables, {X, 1, X}},
			{.Charge_Rate, .Decrease, {50, X, X}},
			{.Overheat_Delay, .Increase, {50, X, X}},
		},
	},
	.Improved_Charge = {
		levels = 3,
		weapon = NONE,
		mods = {
			{.Maximum_Charge, .Increase, {10, 20, 30}},
			{.Charge_Rate, .Increase, {10, 20, 30}},
		},
	},
	.Shield_Regen = {
		levels = 3,
		weapon = NONE,
		mods = {
			{.Shield_Regenerates, .Enables, {1, X, X}},
			// The design lists these as seconds and percent per second
			// outright (its "decreased" describes the trend across levels),
			// so they are flat amounts over a base of none.
			{.Recharge_Delay, .Extra, {30, 15, 0}},
			{.Shield_Regen_Rate, .Extra, {1, 2, X}},
		},
	},
	.Ground_Variant_1 = {
		levels = 3,
		weapon = WEAPON_PLASMA_BOMB,
		mods = {
			// Firing backwards is the passive's premise rather than a listed
			// stat; as one, it shows on the reward screen like the rest.
			// The design's shorter volley delay (10, 20) is gone: a burst
			// already lands a bomb every two steps, the most a target takes,
			// so bombs any closer were ignored and it cost 9-19% of the DPS.
			// Nothing but damage per hit can add to a lone target, so the
			// DPS report's bands come from Projectile_Damage, a stat the
			// design does not have. The extra lane adds only on groups.
			{.Fires_Backwards, .Enables, {1, X, X}},
			{.Projectile_Damage, .Increase, {15, 30, 50}},
			{.Extra_Projectiles, .Extra, {X, X, 1}},
		},
	},
	// The weapon passives below are tuned by the DPS report (mise run
	// dps:report; docs/dps-report.md), not the design's numbers: level 1
	// adds 10-20% to the weapon's DPS, level 2 20-40%, level 3 40-60%, as
	// the report's Gain column measures it. A target takes one hit every
	// two steps at most, so a second lane arriving with the first adds
	// nothing to a lone target, and a firing delay only counts once it
	// rounds to a whole step less.
	.Weapon_1 = {
		levels = 3,
		weapon = WEAPON_ION_CANNON,
		mods = {
			{.Extra_Projectiles, .Extra, {1, X, X}},
			{.Firing_Delay, .Decrease, {X, 20, X}},
			{.Accelerating_Projectiles, .Enables, {X, X, 1}},
			{.Initial_Projectile_Speed, .Decrease, {X, X, 50}},
		},
	},
	.Weapon_2 = {
		levels = 3,
		weapon = WEAPON_BACTA_GUN,
		mods = {
			{.Firing_Delay, .Decrease, {20, X, 40}},
			{.Extra_Projectiles, .Extra, {X, 2, 4}},
			{.Projectile_Lifetime, .Increase, {10, 20, 50}},
		},
	},
	.Weapon_3 = {
		levels = 3,
		weapon = WEAPON_REAR_GUN,
		mods = {
			// Level 3 is +40% at most: the bare Rear Gun already lands two
			// thirds of the hits a lone target takes, and a second extra
			// volley measures the same as one.
			{.Firing_Delay, .Decrease, {10, 20, X}},
			{.Extra_Volley, .Extra, {X, X, 1}},
			{.Side_Firing_Volley, .Enables, {X, X, 1}},
		},
	},
	.Weapon_4 = {
		levels = 3,
		weapon = WEAPON_PHOTON_BEAM,
		mods = {
			// The firing delay steps back at level 3, where the extra volley
			// takes over; 40% with it would be +90%.
			{.Firing_Delay, .Decrease, {20, 40, 10}},
			{.Extra_Volley, .Extra, {X, X, 1}},
		},
	},
}

Passive_Levels :: [Passive]u8


// A modifier's value at `level` (1-based): the last entry up to it that is
// not x. ok is false when there is none, and the modifier does nothing.
mod_value :: proc "contextless" (m: Mod, level: u8) -> (v: i16, ok: bool) {
	for l in 0 ..< min(int(level), MAX_PASSIVE_LEVELS) {
		if m.at[l] != X {
			v, ok = m.at[l], true
		}
	}
	return
}

// Every held passive's contribution to `stat`, summed. `weapon` is the
// weapon the stat is for (NONE for the ship): a weapon passive only counts
// for its own weapon.
stat_total :: proc "contextless" (levels: ^Passive_Levels, stat: Stat, weapon: Res_ID) -> (t: Stat_Total) {
	for &def, pa in PASSIVES {
		lv := levels[pa]
		if lv == 0 || (def.weapon != NONE && def.weapon != weapon) {
			continue
		}
		for m in def.mods {
			if m.stat != stat {
				continue
			}
			v, ok := mod_value(m, lv)
			if !ok {
				continue
			}
			switch m.kind {
			case .Increase:
				t.percent += i32(v)
			case .Decrease:
				t.percent -= i32(v)
			case .Extra:
				t.extra += i32(v)
			case .Enables:
				t.enabled ||= v != 0
			}
		}
	}
	return
}


passive_maxed :: #force_inline proc "contextless" (levels: ^Passive_Levels, pa: Passive) -> bool {
	return levels[pa] >= PASSIVES[pa].levels
}

// Whether a passive may be offered on the way into level `next`: a weapon
// passive needs its weapon in the data and flyable there (the Ion Cannon,
// say, is gone after level 3). Where players keep their weapons
// (sim.weapons_kept) a weapon is kept once unlocked, so its passive is
// offered from then on.
passive_available :: proc "contextless" (s: ^sim.State, pa: Passive, next: i32) -> bool {
	w := PASSIVES[pa].weapon
	if w == NONE {
		return true
	}
	kept := sim.weapons_kept(s)
	for &wd in s.defs.weapons {
		if wd.id == w {
			return wd.type == sim.WEP_GROUND || (wd.minimum_level_available <= next && (kept || next <= wd.maximum_level_available))
		}
	}
	return false
}

// A player's passives, on their entity. They last the session, not the
// level.
Passive_State :: struct {
	passives:  Passive_Levels,
	regen_acc: i32, // eighths of a percent towards the next, times step_hz
}

levels_of :: #force_inline proc "contextless" (s: ^sim.State, player: $I) -> ^Passive_Levels {
	return &sim.get(s.ecs, sim.player_entity(i32(player)), Passive_State).passives
}

// Everything the passives a player holds add to a stat.
@(private = "file")
provide :: proc "contextless" (s: ^sim.State, player: i32, stat: Stat, weapon: Res_ID) -> Stat_Total {
	return stat_total(levels_of(s, player), stat, weapon)
}

// A player's shots of a weapon are shaped while they hold its passive.
@(private = "file")
shapes :: proc "contextless" (s: ^sim.State, player: i32, weapon: Res_ID) -> bool {
	levels := levels_of(s, player)
	for &def, pa in PASSIVES {
		if def.weapon == weapon && levels[pa] > 0 {
			return true
		}
	}
	return false
}

// Ship passives.

RISKY_REWARD_SECONDS :: 20
@(private = "file") RISKY_REWARD_UNIT :: Res_ID{'p', 'i', '2', 'k'} // "Pickup - 2000"
@(private = "file") RISKY_REWARD_MARGIN :: 48

// Random sites for draws the original never makes. oracle:diff never meets
// them: no demo holds a passive.
@(private = "file") SITE_RISKY_X :: sim.Site(0xe0000001)
@(private = "file") SITE_RISKY_Y :: sim.Site(0xe0000002)

// A 2000-point pickup somewhere on screen every RISKY_REWARD_SECONDS, for a
// player in play.
@(private = "file")
risky_reward_stage :: proc(s: ^sim.State, p: sim.Player, ps: ^sim.Player_Step) -> bool {
	if p.state != .Playing {
		return true
	}
	if stats.player_stat(s, p.number, .Risky_Reward).enabled && !sim.single(s, sim.Level_Info).ending &&
	   ps.time > 0 && ps.time % (RISKY_REWARD_SECONDS * stats.step_hz(s)) == 0 {
		w, h := sim.view_width(s.defs), sim.view_height(s.defs)
		req := sim.spawn_request(RISKY_REWARD_UNIT)
		req.loc = {
			f32(sim.roll_int(s, RISKY_REWARD_MARGIN, w - RISKY_REWARD_MARGIN, SITE_RISKY_X)),
			f32(sim.roll_int(s, RISKY_REWARD_MARGIN, h * 2 / 3, SITE_RISKY_Y)),
		}
		lifecycle.eg_request_spawn(s, req)
	}
	return true
}

// Steps without damage before shields start to refill.
@(private = "file")
regen_wait :: #force_inline proc "contextless" (s: ^sim.State, p: sim.Player) -> i32 {
	return stats.player_stat(s, p.number, .Recharge_Delay).extra * stats.step_hz(s)
}

// Shields climb in the eighths shields_set rounds to: regen_acc gathers
// eight times the rate per step, and each step_hz of it is one eighth, so a
// rate of r percent a second is exactly r percent every step_hz steps. The
// wait is the ship's calm (sim.Hull), which damage, appearing and a new
// level set back to zero. That also drops what regen_acc has gathered: calm
// is zero here only on the first step after, since the core's count runs
// right after this, so with no wait at all (Recharge_Delay's last level)
// the climb still starts over.
shield_regen_stage :: proc(s: ^sim.State, p: sim.Player, ps: ^sim.Player_Step) -> bool {
	if p.state != .Playing || !stats.player_stat(s, p.number, .Shield_Regenerates).enabled {
		return true
	}
	st := sim.get(s.ecs, sim.player_entity(p.number), Passive_State)
	if p.calm == 0 {
		st.regen_acc = 0
	}
	if p.calm < regen_wait(s, p) {
		return true
	}
	if p.shields >= 100 {
		st.regen_acc = 0
		return true
	}
	hz := stats.step_hz(s)
	st.regen_acc += 8 * stats.player_stat(s, p.number, .Shield_Regen_Rate).extra
	for st.regen_acc >= hz {
		st.regen_acc -= hz
		collision_system.player_shields_add(s, p, 0.125)
	}
	return true
}

// For presentation: whether the ship's shields are refilling this step.
player_regenerating :: proc "contextless" (s: ^sim.State, p: sim.Player) -> bool {
	if !sim.mod_on(s, ID) || p.state != .Playing || p.shields >= 100 || !stats.player_stat(s, p.number, .Shield_Regenerates).enabled {
		return false
	}
	return p.calm >= regen_wait(s, p)
}

// Gives the players their passives, none held, as the session starts.
@(private = "file")
setup_system :: proc(s: ^sim.State, step: ^sim.Step) {
	for i in 0 ..< i32(sim.MAX_PLAYERS) {
		sim.add(s.ecs, sim.player_entity(i), Passive_State{})
	}
}

ID: sim.Plugin_ID

@(private = "file", rodata)
DEPS := []string{"extra_prefs"}
@(private = "file", rodata)
BEFORE_CALM := []string{"calm"}

// Its components go on the session's entities once they exist, and before
// the players are set up with them.
@(private = "file", rodata)
SETUP_AFTER := []string{"session_setup"}
@(private = "file", rodata)
SETUP_BEFORE := []string{"players_setup"}

@(init)
register :: proc "contextless" () {
	context = runtime.default_context()
	ID = sim.plugin_register({
		name        = "passives",
		label       = "PASSIVE UPGRADES",
		description = "Upgrades to the ship and its weapons, a level at a time",
		deps        = DEPS,
		session     = true,
	})
	sim.component_register(Passive_State, sim.MAX_PLAYERS)
	sim.system_register({name = "passives_setup", after = SETUP_AFTER, before = SETUP_BEFORE, plugin = ID, kind = .Setup, run = setup_system})
	// Where G_Player::Process would have them: after the weapons fire, and
	// ahead of the core's count of the ship's calm, which they read.
	sim.player_stage_register({name = "shield_regen", before = BEFORE_CALM, plugin = ID, run = shield_regen_stage})
	sim.player_stage_register({name = "risky_reward", before = BEFORE_CALM, plugin = ID, run = risky_reward_stage})
	sim.stat_provider_register({plugin = ID, total = provide, shapes = shapes})
}
