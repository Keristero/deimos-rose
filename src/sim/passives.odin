package sim

// Easy mode's passive upgrades: new content, not the original's. The design
// is notes/passive-upgrades-and-easy-mode.md; docs/passive-upgrades.md
// records how each entry was read.
//
// A passive has one to three levels, and each level lists modifiers to named
// stats. Every stat is worked out afresh from the levels a player holds
// whenever it is needed, never stored, so passives that touch the same stat
// combine instead of overwriting each other:
//
// - Increase and Decrease are percentages of the base value. All of them,
//   from every passive held, are summed first, and the base is scaled once
//   by 100 + the sum (never below zero).
// - Extra is a flat amount; all of them are summed.
// - Enables is a switch; on if any passive held turns it on.
//
// Within one passive only the level held counts, not the levels below it
// ((10,x,30) is 30 at level 3, not 40). An `x` (X below) leaves the value as
// the level below had it; a stat whose levels up to the one held are all x
// is not touched at all.
//
// The levels live in Player.passives, inside State, so rollback snapshots and
// the reconnect resync (a copy of State) carry them. With none held, every
// hook below returns what the original code computes, unchanged -- the
// oracle's demos never hold one, and must stay exact.

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

Stat_Total :: struct {
	percent: i32, // increases minus decreases
	extra:   i32,
	enabled: bool,
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

// base scaled by 100 + pct percent, rounded to the nearest whole (halves
// up) and never below zero. pct == 0 is base exactly.
scale_i32 :: proc "contextless" (base, pct: i32) -> i32 {
	if pct == 0 {
		return base
	}
	v := base * max(100 + pct, 0)
	return v >= 0 ? (v + 50) / 100 : -((-v + 50) / 100)
}

scale_f32 :: proc "contextless" (base: f32, pct: i32) -> f32 {
	if pct == 0 {
		return base
	}
	return base * f32(max(100 + pct, 0)) / 100
}

player_stat :: #force_inline proc "contextless" (s: ^State, player: i32, stat: Stat, weapon: Res_ID = NONE) -> Stat_Total {
	return stat_total(&s.players[player].passives, stat, weapon)
}

// A weapon stat for the weapon at index `weapon` in Defs.weapons.
weapon_stat :: proc "contextless" (s: ^State, player: i32, weapon: i32, stat: Stat) -> Stat_Total {
	if weapon == NO_WEAPON || player < 0 {
		return {}
	}
	return stat_total(&s.players[player].passives, stat, s.defs.weapons[weapon].id)
}

passive_maxed :: #force_inline proc "contextless" (levels: ^Passive_Levels, pa: Passive) -> bool {
	return levels[pa] >= PASSIVES[pa].levels
}

// Whether a passive may be offered on the way into level `next`: a weapon
// passive needs its weapon in the data and flyable there (the Ion Cannon,
// say, is gone after level 3). Under New Weapons (`kept`) a weapon is kept
// once unlocked (loadout_unlocked), so its passive is offered from then on.
passive_available :: proc "contextless" (d: ^Defs, pa: Passive, next: i32, kept := false) -> bool {
	w := PASSIVES[pa].weapon
	if w == NONE {
		return true
	}
	for &wd in d.weapons {
		if wd.id == w {
			return wd.type == WEP_GROUND || (wd.minimum_level_available <= next && (kept || next <= wd.maximum_level_available))
		}
	}
	return false
}

// Shots carry which weapon passive fired them, so the passive can shape them
// after they spawn: 0 for none, else the passive's index + 1.
passive_tag :: #force_inline proc "contextless" (pa: Passive) -> u8 {
	return u8(pa) + 1
}

tag_passive :: #force_inline proc "contextless" (tag: u8) -> (Passive, bool) {
	if tag == 0 {
		return {}, false
	}
	return Passive(tag - 1), true
}

// The tag for shots of `weapon` by `player`, or 0 when the player holds no
// passive for it -- then nothing about the shot changes.
weapon_passive_tag :: proc "contextless" (s: ^State, player: i32, weapon: i32) -> u8 {
	if weapon == NO_WEAPON || player < 0 {
		return 0
	}
	id := s.defs.weapons[weapon].id
	for &def, pa in PASSIVES {
		if def.weapon == id && s.players[player].passives[pa] > 0 {
			return passive_tag(pa)
		}
	}
	return 0
}

@(private = "file") PF_STEP_HZ :: 0x20

@(private = "file")
step_hz :: #force_inline proc "contextless" (s: ^State) -> i32 {
	return max(trunc_i32(s.defs.perm_floats[PF_STEP_HZ]), 1)
}

// Ship passives.

// active_velocity_delta, scaled by Maneuverability.
player_acceleration :: proc "contextless" (s: ^State, p: ^Player, base: f32) -> f32 {
	return scale_f32(base, player_stat(s, p.number, .Maneuverability).percent)
}

RISKY_REWARD_SECONDS :: 20
@(private = "file") RISKY_REWARD_UNIT :: Res_ID{'p', 'i', '2', 'k'} // "Pickup - 2000"
@(private = "file") RISKY_REWARD_MARGIN :: 48

// Random sites for draws the original never makes. oracle:diff never meets
// them: no demo holds a passive.
@(private = "file") SITE_RISKY_X :: Site(0xe0000001)
@(private = "file") SITE_RISKY_Y :: Site(0xe0000002)

// Once a step for a player in play: shield regeneration and the risky reward.
player_passives_process :: proc(s: ^State, p: ^Player, time: i32) {
	if p.state != .Playing {
		return
	}
	player_regen_process(s, p)
	if player_stat(s, p.number, .Risky_Reward).enabled && !s.level_ending &&
	   time > 0 && time % (RISKY_REWARD_SECONDS * step_hz(s)) == 0 {
		w, h := view_width(s.defs), view_height(s.defs)
		req := spawn_request(RISKY_REWARD_UNIT)
		req.loc = {
			f32(random_int(&s.rng, RISKY_REWARD_MARGIN, w - RISKY_REWARD_MARGIN, SITE_RISKY_X)),
			f32(random_int(&s.rng, RISKY_REWARD_MARGIN, h * 2 / 3, SITE_RISKY_Y)),
		}
		eg_request_spawn(s, req)
	}
}

// Shields climb in the eighths shields_set rounds to: regen_acc gathers
// eight times the rate per step, and each step_hz of it is one eighth, so a
// rate of r percent a second is exactly r percent every step_hz steps.
@(private = "file")
player_regen_process :: proc(s: ^State, p: ^Player) {
	if !player_stat(s, p.number, .Shield_Regenerates).enabled {
		return
	}
	hz := step_hz(s)
	if p.regen_wait < player_stat(s, p.number, .Recharge_Delay).extra * hz {
		p.regen_wait += 1
		return
	}
	if p.shields >= 100 {
		p.regen_acc = 0
		return
	}
	p.regen_acc += 8 * player_stat(s, p.number, .Shield_Regen_Rate).extra
	for p.regen_acc >= hz {
		p.regen_acc -= hz
		player_shields_add(s, p, 0.125)
	}
}

// Damage restarts the wait before shields regenerate.
player_regen_interrupt :: #force_inline proc "contextless" (p: ^Player) {
	p.regen_wait, p.regen_acc = 0, 0
}

// For presentation: whether the ship's shields are refilling this step.
player_regenerating :: proc "contextless" (s: ^State, p: ^Player) -> bool {
	if p.state != .Playing || p.shields >= 100 || !player_stat(s, p.number, .Shield_Regenerates).enabled {
		return false
	}
	return p.regen_wait >= player_stat(s, p.number, .Recharge_Delay).extra * step_hz(s)
}

// For presentation: how far an air charge has climbed past the weapon's own
// maximum, 0 at or below it and 1 at the raised one.
player_overcharge :: proc "contextless" (s: ^State, p: ^Player) -> f32 {
	h := &p.weapons
	if h.air_powerup.state != 1 && h.air_powerup.state != 2 || h.air.weapon == NO_WEAPON {
		return 0
	}
	base := weapon_def(s, h.air.weapon).powerup_air_max_power_level
	top := powerup_max_level(s, h, h.air.weapon)
	if top <= base || h.air_powerup.level <= base {
		return 0
	}
	return min(f32(h.air_powerup.level - base) / f32(top - base), 1)
}

// Charging.

// Whether the air weapon charges without the button: Auto Charge, on a
// weapon with a power-up at all.
air_auto_charge :: proc "contextless" (s: ^State, h: ^Weapon_Handler) -> bool {
	if h.air.weapon == NO_WEAPON || !player_stat(s, h.player, .Auto_Charge_Air_To_Air).enabled {
		return false
	}
	wd := weapon_def(s, h.air.weapon)
	return !wd.auto_repeat && (wd.powerup_air_activation_spawn != NONE || wd.powerup_air_release_spawn != NONE)
}

powerup_max_level :: proc "contextless" (s: ^State, h: ^Weapon_Handler, weapon: i32) -> i32 {
	base := weapon_def(s, weapon).powerup_air_max_power_level
	return scale_i32(base, player_stat(s, h.player, .Maximum_Charge, s.defs.weapons[weapon].id).percent)
}

// powerup_air_overload_time, or 0 (never) under Prevent_Overheat.
powerup_overload_time :: proc "contextless" (s: ^State, h: ^Weapon_Handler, weapon: i32) -> i32 {
	base := weapon_def(s, weapon).powerup_air_overload_time
	id := s.defs.weapons[weapon].id
	if player_stat(s, h.player, .Prevent_Overheat, id).enabled {
		return 0
	}
	return scale_i32(base, player_stat(s, h.player, .Overheat_Delay, id).percent)
}

// Whether a charging power-up climbs a level this step. The original climbs
// once every between + 1 steps (level_time + between < time); a changed
// Charge_Rate keeps pace in hundredths of a step instead, since a 10%
// change to a 2-step interval would otherwise round away.
powerup_level_due :: proc "contextless" (s: ^State, h: ^Weapon_Handler, p: ^Powerup, weapon: i32, time: i32) -> bool {
	between := weapon_def(s, weapon).powerup_air_time_between_power_level_changes
	pct := player_stat(s, h.player, .Charge_Rate, s.defs.weapons[weapon].id).percent
	if pct == 0 {
		return p.level_time + between < time
	}
	p.pace += max(100 + pct, 1)
	need := (between + 1) * 100
	if p.pace < need {
		return false
	}
	p.pace -= need
	return true
}

// Firing.

// delay_between_launches, scaled by Firing_Delay.
air_firing_delay :: proc "contextless" (s: ^State, h: ^Weapon_Handler, weapon: i32) -> i32 {
	return scale_i32(weapon_def(s, weapon).delay_between_launches, weapon_stat(s, h.player, weapon, .Firing_Delay).percent)
}

// Steps between the extra volleys of a direct-fire shot (one whose spawn
// list holds its projectiles, not a spawner of them), before Volley_Delay.
// Provisional: no original weapon fires volleys this way to measure; two
// steps is the gap the Rear Gun's and Photon Beam's own spawners leave.
VOLLEY_INTERVAL :: 2

// After a direct-fire shot: the extra volleys it owes, fired one per
// (scaled) VOLLEY_INTERVAL. A spawner weapon's volleys come from its
// spawner instead -- see passive_entity_init.
air_volleys_schedule :: proc "contextless" (s: ^State, h: ^Weapon_Handler) {
	h.volleys_left, h.volley_pace = 0, 0
	if !weapon_is_direct(s, h.air.weapon) {
		return
	}
	h.volleys_left = max(weapon_stat(s, h.player, h.air.weapon, .Extra_Volley).extra, 0)
}

// Whether an owed volley is due this step.
air_volley_due :: proc "contextless" (s: ^State, h: ^Weapon_Handler) -> bool {
	if h.volleys_left <= 0 {
		return false
	}
	h.volley_pace += 100
	need := max(scale_i32(VOLLEY_INTERVAL * 100, weapon_stat(s, h.player, h.air.weapon, .Volley_Delay).percent), 1)
	if h.volley_pace < need {
		return false
	}
	h.volley_pace -= need
	h.volleys_left -= 1
	return true
}

// Whether the next bomb of a ground burst is due. The original drops one
// every delay_between_load_launches + 1 steps; Volley_Delay paces it in
// hundredths, like powerup_level_due.
ground_burst_due :: proc "contextless" (s: ^State, h: ^Weapon_Handler, time: i32) -> bool {
	gw := weapon_def(s, h.ground.weapon)
	pct := weapon_stat(s, h.player, h.ground.weapon, .Volley_Delay).percent
	if pct == 0 {
		return h.ground.last2 + gw.delay_between_load_launches < time
	}
	h.ground_pace += 100
	need := max(scale_i32((gw.delay_between_load_launches + 1) * 100, pct), 1)
	if h.ground_pace < need {
		return false
	}
	h.ground_pace -= need
	return true
}

ground_fires_backwards :: proc "contextless" (s: ^State, h: ^Weapon_Handler) -> bool {
	return weapon_stat(s, h.player, h.ground.weapon, .Fires_Backwards).enabled
}

// A weapon is direct-fire when its spawn list holds player projectiles
// itself; otherwise it spawns a spawner of them (the Rear Gun, the Photon
// Beam), whose own spawn sets are the lanes.
weapon_is_direct :: proc "contextless" (s: ^State, weapon: i32) -> bool {
	for &sp in weapon_def(s, weapon).spawns {
		if unit_is_projectile(s, sp.unit) {
			return true
		}
	}
	return false
}

@(private = "file")
unit_is_projectile :: proc "contextless" (s: ^State, id: Res_ID) -> bool {
	if id == NONE {
		return false
	}
	ui := unit_index(s.defs, id)
	return ui >= 0 && s.defs.units[ui].player_projectile
}

// Lanes: extra projectiles continue the spread.
//
// A volley's projectiles are lanes, ordered across the spread, each an
// offset and a heading. m = n + extra lanes are placed at fractional
// positions t = j - extra/2 along the original n, interpolating between
// neighbours and carrying the end pairs' spacing on beyond them. An even
// extra keeps every original lane and adds half each side; an odd one shifts
// them all half a step, keeping the pattern symmetric (the Photon Beam's
// -6/0/6 with 3 extra is -15..15 in steps of 6). A lone lane spreads
// sideways by LANE_SPACING.

Lane :: struct {
	x, y:  f32,
	angle: f32, // degrees, signed about straight ahead
	src:   i32, // the original lane nearest, whose unit and timing it takes
}

MAX_LANES :: 32
MAX_EXTRA_SPAWNS :: 16 // a weapon's spawns that are not lanes: flashes, spawners
LANE_SPACING :: 12

lanes_extend :: proc "contextless" (base: []Lane, extra: i32, out: []Lane) -> int {
	n := len(base)
	if n == 0 {
		return 0
	}
	m := min(n + int(max(extra, 0)), len(out))
	for j in 0 ..< m {
		out[j] = lane_at(base, f32(j) - f32(extra) / 2)
	}
	return m
}

@(private = "file")
lane_at :: proc "contextless" (base: []Lane, t: f32) -> Lane {
	n := len(base)
	if n == 1 {
		l := base[0]
		l.x += t * LANE_SPACING
		l.src = 0
		return l
	}
	i := clamp(int(floor_f32(t)), 0, n - 2)
	f := t - f32(i)
	a, b := base[i], base[i + 1]
	return {
		x     = a.x + (b.x - a.x) * f,
		y     = a.y + (b.y - a.y) * f,
		angle = a.angle + (b.angle - a.angle) * f,
		src   = i32(clamp(int(floor_f32(t + 0.5)), 0, n - 1)),
	}
}

@(private = "file")
floor_f32 :: proc "contextless" (v: f32) -> f32 {
	t := f32(trunc_i32(v))
	return t > v ? t - 1 : t
}

// Nearest whole, halves away from zero.
round_i32 :: proc "contextless" (v: f32) -> i32 {
	return v < 0 ? -trunc_i32(-v + 0.5) : trunc_i32(v + 0.5)
}

signed_angle :: #force_inline proc "contextless" (deg: i32) -> f32 {
	return f32(deg > 180 ? deg - 360 : deg)
}

wrap_angle :: proc "contextless" (deg: i32) -> i32 {
	a := deg % 360
	return a < 0 ? a + 360 : a
}

// Insertion sort across the spread: by offset, then by heading.
lanes_sort :: proc "contextless" (l: []Lane) {
	for i in 1 ..< len(l) {
		v := l[i]
		j := i
		for j > 0 && (l[j - 1].x > v.x || (l[j - 1].x == v.x && l[j - 1].angle > v.angle)) {
			l[j] = l[j - 1]
			j -= 1
		}
		l[j] = v
	}
}

// A weapon's spawn list, shaped by its passive: the lanes extended, and for
// a backwards ground weapon mirrored behind the ship. Non-projectile entries
// (muzzle flashes, spawners) fire as they are. `emit` receives each spawn.
Weapon_Spawn :: struct {
	unit:        Res_ID,
	x, y:        i32,
	set_heading: bool,
	angle:       i32,
}

weapon_spawns :: proc "contextless" (s: ^State, weapon: i32, player: i32, backwards: bool, out: []Weapon_Spawn) -> int {
	wd := weapon_def(s, weapon)
	extra := weapon_stat(s, player, weapon, .Extra_Projectiles).extra
	base: [MAX_LANES]Lane
	units: [MAX_LANES]Weapon_Spawn
	n := 0
	for &sp in wd.spawns {
		if n < MAX_LANES && unit_is_projectile(s, sp.unit) {
			base[n] = {f32(sp.x_loc), f32(sp.y_loc), sp.set_heading ? signed_angle(sp.angle) : 0, i32(n)}
			units[n] = {sp.unit, sp.x_loc, sp.y_loc, sp.set_heading, sp.angle}
			n += 1
		}
	}
	lanes: [MAX_LANES]Lane
	m := 0
	if extra > 0 && n > 0 {
		lanes_sort(base[:n])
		m = lanes_extend(base[:n], extra, lanes[:])
	}
	count := 0
	push :: proc "contextless" (out: []Weapon_Spawn, count: ^int, sp: Weapon_Spawn, backwards: bool) {
		if count^ >= len(out) {
			return
		}
		sp := sp
		if backwards {
			sp.y = -sp.y
			sp.set_heading = true
			sp.angle = wrap_angle(180 - sp.angle)
		}
		out[count^] = sp
		count^ += 1
	}
	lanes_done := false
	for &sp in wd.spawns {
		if sp.unit == NONE {
			continue
		}
		if m == 0 || !unit_is_projectile(s, sp.unit) {
			push(out, &count, {sp.unit, sp.x_loc, sp.y_loc, sp.set_heading, sp.angle}, backwards)
			continue
		}
		// Every lane goes out where the first projectile entry stood.
		if lanes_done {
			continue
		}
		lanes_done = true
		for l in lanes[:m] {
			src := units[base[l.src].src]
			a := round_i32(l.angle)
			push(out, &count, {src.unit, round_i32(l.x), round_i32(l.y), src.set_heading || a != 0, wrap_angle(a)}, backwards)
		}
	}
	return count
}

// Tagged entities.

// The damage a tagged shot deals, scaled by its passive's Projectile_Damage.
// What it spawns carries the tag (a bomb's blast), so that is scaled too.
passive_damage :: proc "contextless" (s: ^State, e: ^Entity, base: f32) -> f32 {
	pa, ok := tag_passive(e.passive_tag)
	if !ok || e.owner_player < 0 || e.owner_player >= MAX_PLAYERS {
		return base
	}
	return scale_f32(base, stat_total(&s.players[e.owner_player].passives, .Projectile_Damage, PASSIVES[pa].weapon).percent)
}

// Accelerating shots leave at the scaled initial speed and speed up by
// ACCEL_RATE a step to ACCEL_TOP percent of their unit's own speed.
// Provisional: the design names the effect, not the curve.
ACCEL_RATE :: 1.0
ACCEL_TOP :: 150

// Right after a tagged entity spawns (spawn_entity): its passive shapes it.
// A projectile's flight (lifetime, speed); a spawner fired straight from the
// weapon (depth 0) its volleys.
passive_entity_init :: proc(s: ^State, e: ^Entity, time: i32) {
	pa, ok := tag_passive(e.passive_tag)
	if !ok || e.owner_player < 0 || e.owner_player >= MAX_PLAYERS {
		return
	}
	levels := &s.players[e.owner_player].passives
	w := PASSIVES[pa].weapon
	u := unit_of(s, e)
	if u.player_projectile {
		if pct := stat_total(levels, .Projectile_Lifetime, w).percent; pct != 0 && e.timer > 0 {
			e.timer = scale_i32(e.timer, pct)
		}
		speed := speed_from_vector(e.vel)
		if e.stationary || speed == 0 {
			return
		}
		dir := e.vel / speed
		pct := stat_total(levels, .Initial_Projectile_Speed, w).percent
		if stat_total(levels, .Accelerating_Projectiles, w).enabled {
			e.vel = dir * scale_f32(speed, pct)
			e.vel_target = dir * scale_f32(speed, ACCEL_TOP - 100)
			e.vel_delta = dir * ACCEL_RATE
			e.vel_prev = e.vel
		} else if pct != 0 {
			e.vel = dir * scale_f32(speed, pct)
			e.vel_target = e.vel
			e.vel_prev = e.vel
		}
		return
	}
	if e.passive_depth != 0 || e.state < 0 || len(state_of(s, e).spawn_sets) == 0 {
		return
	}
	extra := max(stat_total(levels, .Extra_Volley, w).extra, 0)
	pace := 100
	if pct := stat_total(levels, .Volley_Delay, w).percent; pct != 0 {
		pace = 100 * 100 / max(int(100 + pct), 1)
	}
	if extra == 0 && pace == 100 {
		return
	}
	// The spawner's life, in steps of its own spawn timing: its volleys stop
	// when it is deleted, so one more volley is one more volley period.
	life := e.timer + extra * spawner_volley_period(s, e)
	if pace != 100 {
		e.spawn_pace = i32(pace)
		e.spawn_clock = time
		e.timer = i32((int(life) * 100 + pace - 1) / pace)
	} else {
		e.timer = life
	}
}

// Steps between a spawner's volleys: a repeating set's rate + 1 (a new
// volley is drawn one step, spawned the next), or a volley set's gap between
// entities. The longest across its projectile sets.
@(private = "file")
spawner_volley_period :: proc "contextless" (s: ^State, e: ^Entity) -> (period: i32) {
	period = 1
	for &set in state_of(s, e).spawn_sets {
		if !unit_is_projectile(s, set.spawn) {
			continue
		}
		p := set.repeat_spawns ? set.rate_max + 1 : set.delay_between_entities_max
		period = max(period, p)
	}
	return
}

// spawn_control for a spawner whose volleys a passive has sped up: its
// spawn sets run on their own clock, spawn_pace hundredths of a step per
// step, so a 30% shorter volley delay runs them 100/70 as fast.
passive_paced_spawn_control :: proc(s: ^State, e: ^Entity) {
	e.pace_acc += e.spawn_pace
	for e.pace_acc >= 100 && !e.deleted {
		e.pace_acc -= 100
		spawn_control(s, e, e.spawn_clock)
		e.spawn_clock += 1
	}
}

// One of a tagged spawner's spawn sets firing (spawn_child). Handles its
// projectile sets -- extending the lanes and firing to the sides -- and
// returns false for the rest, which spawn as they are.
passive_spawn_child :: proc(s: ^State, e: ^Entity, set: ^Spawn_Set_Def) -> bool {
	pa, ok := tag_passive(e.passive_tag)
	if !ok || e.owner_player < 0 || e.owner_player >= MAX_PLAYERS || !unit_is_projectile(s, set.spawn) {
		return false
	}
	levels := &s.players[e.owner_player].passives
	w := PASSIVES[pa].weapon
	extra := stat_total(levels, .Extra_Projectiles, w).extra
	side := stat_total(levels, .Side_Firing_Volley, w).enabled
	if extra <= 0 && !side {
		return false
	}
	st := state_of(s, e)
	me := -1
	base: [MAX_LANES]Lane
	n := 0
	for &other, i in st.spawn_sets {
		if n < MAX_LANES && unit_is_projectile(s, other.spawn) {
			if &other == set {
				me = i
			}
			base[n] = {f32(other.x_offset), f32(other.y_offset), other.set_heading ? signed_angle(other.heading_degrees) : 0, i32(i)}
			n += 1
		}
	}
	emit :: proc(s: ^State, e: ^Entity, set: ^Spawn_Set_Def, x, y: i32, heading: i32, explicit: bool) {
		alt := set^
		alt.x_offset, alt.y_offset = x, y
		alt.set_heading = explicit
		alt.heading_degrees = heading
		spawn_child_set(s, e, &alt)
	}
	if extra > 0 && n > 0 {
		lanes_sort(base[:n])
		lanes: [MAX_LANES]Lane
		m := lanes_extend(base[:n], extra, lanes[:])
		for l in lanes[:m] {
			if base[l.src].src != i32(me) {
				continue
			}
			a := round_i32(l.angle)
			emit(s, e, set, round_i32(l.x), round_i32(l.y), wrap_angle(a), set.set_heading || a != 0)
		}
	} else {
		spawn_child_set(s, e, set)
	}
	// Side fire: each forward-facing set also fires outward, left of the
	// centre line to the left and right of it to the right.
	if side && (!set.set_heading || set.heading_degrees == 0) {
		if set.x_offset <= 0 {
			emit(s, e, set, set.x_offset, set.y_offset, 270, true)
		}
		if set.x_offset >= 0 {
			emit(s, e, set, set.x_offset, set.y_offset, 90, true)
		}
	}
	return true
}
