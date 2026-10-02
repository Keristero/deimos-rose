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
	name:   string, // lower case, and unique: its icon is assets/icons/passives/<name>.png
	label:  string, // as the reward screen names it
	plugin: sim.Plugin_ID, // another plugin's passive names it (passive_register); this plugin's own leave it CORE
	levels: u8,
	// NONE for a ship passive. A weapon passive's modifiers apply to that
	// weapon's own shots alone, and it is only offered while the weapon can
	// be flown (see passive_available).
	weapon: Res_ID,
	// A weapon passive for the weapon's charge: its modifiers apply to how
	// the charge climbs and what its release fires, and not to the shots,
	// as a passive without it is the other way round (the stat providers'
	// scopes, sim.Stat_Provider). A ship passive's apply to both.
	charge: bool,
	// Passives that share one are alternatives: taking one gives up any of
	// the others held (passive_take). "" for none.
	exclusive: string,
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

// The passives this plugin brings, in the order the design lists them.
// Their ids are fixed; other plugins' passives follow them, numbered as
// they register (passive_register): Weapon 5 and 6, for the plugins'
// weapons, are New Weapon Upgrades' (plugins/new_weapon_passives).
Own :: enum u8 {
	Improved_Manoeuvring,
	Auto_Charge,
	Improved_Charge,
	Shield_Regen,
	Ground_Variant_1,
	Weapon_1,
	Weapon_2,
	Weapon_3,
	Weapon_4,
	Ground_Variant_2,
	// The air weapons' charge passives, in the order they were added, so
	// that the ids before them stay as they were.
	Weapon_4_Charge,
	Weapon_3_Charge,
}

// A passive, by its id: this plugin's own first (Own), then other plugins'.
Passive :: distinct u8

IMPROVED_MANOEUVRING :: Passive(Own.Improved_Manoeuvring)
AUTO_CHARGE :: Passive(Own.Auto_Charge)
IMPROVED_CHARGE :: Passive(Own.Improved_Charge)
SHIELD_REGEN :: Passive(Own.Shield_Regen)
GROUND_VARIANT_1 :: Passive(Own.Ground_Variant_1)
WEAPON_1 :: Passive(Own.Weapon_1)
WEAPON_2 :: Passive(Own.Weapon_2)
WEAPON_3 :: Passive(Own.Weapon_3)
WEAPON_4 :: Passive(Own.Weapon_4)
GROUND_VARIANT_2 :: Passive(Own.Ground_Variant_2)
WEAPON_4_CHARGE :: Passive(Own.Weapon_4_Charge)
WEAPON_3_CHARGE :: Passive(Own.Weapon_3_Charge)

MAX_PASSIVES :: 32

@(private = "file")
OWN := [Own]Passive_Def {
	.Improved_Manoeuvring = {
		name   = "improved_manoeuvring",
		label  = "IMPROVED MANOEUVRING",
		levels = 2,
		weapon = NONE,
		mods = {
			{.Maneuverability, .Increase, {20, 50, X}},
			{.Risky_Reward, .Enables, {X, 1, X}},
		},
	},
	.Auto_Charge = {
		name   = "auto_charge",
		label  = "AUTO CHARGE",
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
		name   = "improved_charge",
		label  = "IMPROVED CHARGE",
		levels = 3,
		weapon = NONE,
		mods = {
			{.Maximum_Charge, .Increase, {10, 20, 30}},
			{.Charge_Rate, .Increase, {10, 20, 30}},
		},
	},
	.Shield_Regen = {
		name   = "shield_regen",
		label  = "SHIELD REGENERATION",
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
	// The ground weapon's two charges (stats.ground_charges), of which a
	// player holds one: notes/extra-weapons-and-passives-3.md. The first
	// was the bomb turned round for good; now the burst stays ahead and
	// the charge is aimed. The charge and its aim are the passives'
	// premise rather than listed stats; as stats, they show on the reward
	// screen like the rest. Its damage is the charge's alone, so the
	// burst is the bomb's own.
	.Ground_Variant_1 = {
		name      = "ground_variant_1",
		label     = "REVERSE PLASMA BOMB",
		levels    = 3,
		weapon    = WEAPON_PLASMA_BOMB,
		charge    = true,
		exclusive = "ground_charge",
		mods = {
			{.Ground_Charge, .Enables, {1, X, X}},
			{.Charge_Aim_Behind, .Enables, {1, X, X}},
			{.Projectile_Damage, .Increase, {340, 780, 1370}},
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
		name   = "weapon_1",
		label  = "ION CANNON UPGRADE",
		levels = 3,
		weapon = WEAPON_ION_CANNON,
		mods = {
			// Level 3's shots leave at half speed and take a second to get
			// back to full (stats.ACCEL_SECONDS), which only delays them;
			// its gain is the two extra lanes, 4 in all.
			{.Extra_Projectiles, .Extra, {1, X, 2}},
			{.Firing_Delay, .Decrease, {X, 20, X}},
			{.Accelerating_Projectiles, .Enables, {X, X, 1}},
			{.Initial_Projectile_Speed, .Decrease, {X, X, 50}},
		},
	},
	.Weapon_2 = {
		name   = "weapon_2",
		label  = "BACTA GUN UPGRADE",
		levels = 3,
		weapon = WEAPON_BACTA_GUN,
		mods = {
			{.Firing_Delay, .Decrease, {20, X, 40}},
			{.Extra_Projectiles, .Extra, {X, 2, 4}},
			{.Projectile_Lifetime, .Increase, {10, 20, 50}},
		},
	},
	.Weapon_3 = {
		name   = "weapon_3",
		label  = "REAR GUN UPGRADE",
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
		name   = "weapon_4",
		label  = "PHOTON BEAM UPGRADE",
		levels = 3,
		weapon = WEAPON_PHOTON_BEAM,
		mods = {
			// The firing delay steps back at level 3, where the extra volley
			// takes over; 40% with it would be +90%.
			{.Firing_Delay, .Decrease, {20, 40, 10}},
			{.Extra_Volley, .Extra, {X, X, 1}},
		},
	},
	// The other ground charge (see Ground Variant 1): its crosshair
	// circles the ship, and its bomb hits harder for being slower to aim.
	.Ground_Variant_2 = {
		name      = "ground_variant_2",
		label     = "ORBITING PLASMA BOMB",
		levels    = 3,
		weapon    = WEAPON_PLASMA_BOMB,
		charge    = true,
		exclusive = "ground_charge",
		mods = {
			{.Ground_Charge, .Enables, {1, X, X}},
			{.Charge_Aim_Around, .Enables, {1, X, X}},
			{.Projectile_Damage, .Increase, {560, 1200, 2050}},
		},
	},
	// The charge passives for the air weapons, from
	// notes/extra-weapons-and-passives-3.md, tuned in the DPS report's
	// Charge-shots set.
	.Weapon_4_Charge = {
		name   = "weapon_4_charge",
		label  = "PHOTON BEAM CHARGE",
		levels = 3,
		weapon = WEAPON_PHOTON_BEAM,
		charge = true,
		mods = {
			// Over the weapon's own max, a release fans out 2 more lanes
			// for every 25% of it (stats.overcharge_lanes): 2 at level 1,
			// 4 at level 3, back to its own 3 as its levels are spent.
			// The wider lanes mostly miss a single target, so in the
			// Charge-shots set they gain 0/5/6%; past the design, each
			// level also charges faster, for 16%, 33% and 48%.
			{.Overcharge_Projectiles, .Enables, {1, X, X}},
			{.Maximum_Charge, .Increase, {25, 40, 50}},
			{.Charge_Rate, .Increase, {20, 40, 80}},
		},
	},
	.Weapon_3_Charge = {
		name   = "weapon_3_charge",
		label  = "REAR GUN CHARGE",
		levels = 3,
		weapon = WEAPON_REAR_GUN,
		charge = true,
		mods = {
			// The release's bubbles wear down in place of bursting on
			// their first hit (Wears_Down): each gives its damage times its
			// size, so a larger one gives more as well as reaching more.
			// The wear alone gains 9% in the Charge-shots set: a bubble no
			// longer bursts on a target it cannot hurt (inside its hit
			// delay), nor spends a whole hit on one nearly dead. The sizes
			// make it 16%, 30% and 50%. The longer life gains nothing
			// there, where every bubble hits before it would expire; in
			// play it reaches further.
			{.Wears_Down, .Enables, {1, X, X}},
			{.Shot_Scale, .Increase, {10, 25, 45}},
			{.Projectile_Lifetime, .Increase, {20, 40, 60}},
		},
	},
}

@(private = "file")
registered: sim.Registry(Passive_Def, MAX_PASSIVES - len(Own))

// Adds another plugin's passive, from its registration step, and returns
// its id. Its def.plugin is that plugin: the passive is offered only while
// the plugin is on, and its modifiers count through this plugin's stat
// provider, so they need this plugin on too.
passive_register :: proc(def: Passive_Def, loc := #caller_location) -> Passive {
	assert(def.plugin != sim.CORE, "passives: a registered passive names its plugin", loc)
	return Passive(len(Own) + sim.registry_add(&registered, def, loc))
}

// How many passives there are: ids run from 0 to one short of this.
passive_count :: #force_inline proc "contextless" () -> int {
	return len(Own) + registered.count
}

passive_def :: proc "contextless" (pa: Passive) -> ^Passive_Def {
	if int(pa) < len(Own) {
		return &OWN[Own(pa)]
	}
	return &registered.items[int(pa) - len(Own)]
}

passive_by_name :: proc "contextless" (name: string) -> (Passive, bool) {
	for i in 0 ..< passive_count() {
		if passive_def(Passive(i)).name == name {
			return Passive(i), true
		}
	}
	return 0, false
}

// The levels a player holds of each passive, by id.
Passive_Levels :: [MAX_PASSIVES]u8

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
// weapon the stat is for (NONE for the ship), and `charge` whether it is
// for the weapon's charge or its shots: a weapon passive only counts for
// its own weapon, in its own scope (Passive_Def.charge).
stat_total :: proc "contextless" (levels: ^Passive_Levels, stat: Stat, weapon: Res_ID, charge := false) -> (t: Stat_Total) {
	for i in 0 ..< passive_count() {
		def := passive_def(Passive(i))
		lv := levels[i]
		if lv == 0 || !passive_applies(def, weapon, charge) {
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


// Whether a passive's modifiers count for a stat of `weapon` in that scope.
passive_applies :: #force_inline proc "contextless" (def: ^Passive_Def, weapon: Res_ID, charge: bool) -> bool {
	return def.weapon == NONE || (def.weapon == weapon && def.charge == charge)
}

// The passive held that taking `pa` would give up: one of its alternatives
// (Passive_Def.exclusive). ok is false where there is none.
passive_replaces :: proc "contextless" (levels: ^Passive_Levels, pa: Passive) -> (Passive, bool) {
	group := passive_def(pa).exclusive
	if group == "" || levels[pa] > 0 {
		return 0, false
	}
	for i in 0 ..< passive_count() {
		if Passive(i) != pa && levels[i] > 0 && passive_def(Passive(i)).exclusive == group {
			return Passive(i), true
		}
	}
	return 0, false
}

// Takes a level of `pa`, giving up its alternatives held: the one taken
// starts again from level 1.
passive_take :: proc "contextless" (levels: ^Passive_Levels, pa: Passive) {
	for other, ok := passive_replaces(levels, pa); ok; other, ok = passive_replaces(levels, pa) {
		levels[other] = 0
	}
	levels[pa] += 1
}

passive_maxed :: #force_inline proc "contextless" (levels: ^Passive_Levels, pa: Passive) -> bool {
	return levels[pa] >= passive_def(pa).levels
}

// Whether a passive may be offered on the way into level `next`: a weapon
// passive needs its weapon in the data, allowed in the session
// (sim.weapon_allowed: a plugin's weapon while its plugin is on) and flyable there (the Ion Cannon,
// say, is gone after level 3). Where players keep their weapons
// (sim.weapons_kept) a weapon is kept once unlocked, so its passive is
// offered from then on.
passive_available :: proc "contextless" (s: ^sim.State, pa: Passive, next: i32) -> bool {
	def := passive_def(pa)
	if !sim.mod_on(s, def.plugin) {
		return false
	}
	w := def.weapon
	if w == NONE {
		return true
	}
	kept := sim.weapons_kept(s)
	for &wd in s.defs.weapons {
		if wd.id == w {
			if !sim.weapon_allowed(s, &wd) {
				return false
			}
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
	return &sim.player_component(s, player, Passive_State).passives
}

// Everything the passives a player holds add to a stat.
@(private = "file")
provide :: proc "contextless" (s: ^sim.State, player: i32, stat: Stat, weapon: Res_ID, charge: bool) -> Stat_Total {
	return stat_total(levels_of(s, player), stat, weapon, charge)
}

// A player's shots of a weapon are shaped while they hold its passive, and
// its charge's while they hold its charge passive.
@(private = "file")
shapes :: proc "contextless" (s: ^sim.State, player: i32, weapon: Res_ID, charge: bool) -> bool {
	levels := levels_of(s, player)
	for i in 0 ..< passive_count() {
		def := passive_def(Passive(i))
		if def.weapon == weapon && def.charge == charge && levels[i] > 0 {
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
	st := sim.player_component(s, p.number, Passive_State)
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

ID: sim.Plugin_ID

@(private = "file", rodata)
DEPS := []string{"extra_prefs"}
@(private = "file", rodata)
BEFORE_CALM := []string{"calm"}
@(private = "file", rodata)
CLOUDS_AFTER := []string{"entities"}
@(private = "file", rodata)
CLOUDS_BEFORE := []string{"sweep"}

register :: proc() {
	ID = sim.plugin_register({
		name        = "passives",
		label       = "PASSIVE UPGRADES",
		description = "Upgrades to the ship and its weapons, a level at a time",
		deps        = DEPS,
		session     = true,
	})
	// None held, as the session starts.
	sim.kind_component(.Player, Passive_State{}, ID)
	// Where G_Player::Process would have them: after the weapons fire, and
	// ahead of the core's count of the ship's calm, which they read.
	sim.player_stage_register({name = "shield_regen", before = BEFORE_CALM, plugin = ID, run = shield_regen_stage})
	sim.player_stage_register({name = "risky_reward", before = BEFORE_CALM, plugin = ID, run = risky_reward_stage})
	sim.stat_provider_register({plugin = ID, total = provide, shapes = shapes})
	// Corrosive clouds (clouds.odin): left by the shots' hits, they harm
	// once the entities have moved and hit, ahead of the sweep of the
	// destroyed.
	sim.kind_component(.Session, Clouds{}, ID)
	sim.shot_hit_register({plugin = ID, hit = cloud_hit})
	sim.system_register({name = "clouds", after = CLOUDS_AFTER, before = CLOUDS_BEFORE, plugin = ID, run = cloud_system})
}

@(init)
register_step :: proc "contextless" () {
	sim.register_step(.Plugin, "plugins/passives register", register)
}
