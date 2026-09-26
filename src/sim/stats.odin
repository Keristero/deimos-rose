package sim

// Stats: the numbers the core's mechanics read that a plugin may change --
// how fast a ship accelerates, how a weapon charges, fires and what its
// shots do -- and the mechanics that follow them where the original has
// none (extra lanes and volleys, paced charging, shaped shots). Plugins
// supply the changes through stat providers (hooks.odin), passive upgrades
// (plugins/passives) among them.
//
// Every stat is worked out afresh whenever it is needed, never stored, so
// providers that touch the same stat combine instead of overwriting each
// other:
//
// - `percent` scales the base once, by 100 + the sum (never below zero);
// - `extra` is a flat amount;
// - `enabled` is a switch, on if anything turns it on.
//
// With no provider on, every stat is zero and every procedure below returns
// what the original code computes, unchanged: the oracle's demos, and
// classic mode, run none.

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

// A stat for `player`: for their ship, or for a weapon by its id.
player_stat :: #force_inline proc "contextless" (s: ^State, player: i32, stat: Stat, weapon: Res_ID = NONE) -> Stat_Total {
	return stat_of(s, player, stat, weapon)
}

// A weapon stat for the weapon at index `weapon` in Defs.weapons.
weapon_stat :: proc "contextless" (s: ^State, player: i32, weapon: i32, stat: Stat) -> Stat_Total {
	if weapon == NO_WEAPON || player < 0 {
		return {}
	}
	return stat_of(s, player, stat, s.defs.weapons[weapon].id)
}

// Shots carry the weapon that fired them when a provider shapes it, so that
// they can be shaped after they spawn (Shaped): 0 for none, else the
// weapon's index + 1. What a shaped spawner spawns carries it too.
shot_shaper :: proc "contextless" (s: ^State, player: i32, weapon: i32) -> u8 {
	if weapon == NO_WEAPON || player < 0 || !stat_shapes(s, player, s.defs.weapons[weapon].id) {
		return 0
	}
	return u8(weapon + 1)
}

// The weapon a shaped entity's stats are read for.
shaped_weapon :: #force_inline proc "contextless" (s: ^State, shaped_by: u8) -> (Res_ID, bool) {
	if shaped_by == 0 {
		return NONE, false
	}
	return s.defs.weapons[shaped_by - 1].id, true
}

@(private = "file") PF_STEP_HZ :: 0x20

// Game steps a second.
step_hz :: #force_inline proc "contextless" (s: ^State) -> i32 {
	return max(trunc_i32(s.defs.perm_floats[PF_STEP_HZ]), 1)
}

// The ship.

// active_velocity_delta, scaled by Maneuverability.
player_acceleration :: proc "contextless" (s: ^State, p: Player, base: f32) -> f32 {
	return scale_f32(base, player_stat(s, p.number, .Maneuverability).percent)
}


// For presentation: how far an air charge has climbed past the weapon's own
// maximum, 0 at or below it and 1 at the raised one.
player_overcharge :: proc "contextless" (s: ^State, p: Player) -> f32 {
	h := p.weapons
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
// spawner instead -- see shaped_entity_init.
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

// Shaped entities.

// The damage a shaped shot deals, scaled by its weapon's Projectile_Damage.
// What it spawns is shaped too (a bomb's blast), so that is scaled as well.
shot_damage :: proc "contextless" (s: ^State, e: Entity, base: f32) -> f32 {
	w, ok := shaped_weapon(s, e.shaped_by)
	if !ok || e.owner_player < 0 || e.owner_player >= MAX_PLAYERS {
		return base
	}
	return scale_f32(base, stat_of(s, e.owner_player, .Projectile_Damage, w).percent)
}

// Accelerating shots leave at the scaled initial speed and speed up by
// ACCEL_RATE a step to ACCEL_TOP percent of their unit's own speed.
// Provisional: the design names the effect, not the curve.
ACCEL_RATE :: 1.0
ACCEL_TOP :: 150

// Right after a shaped entity spawns (spawn_entity): its weapon's stats
// shape it. A projectile's flight (lifetime, speed); a spawner fired
// straight from the weapon (depth 0) its volleys.
shaped_entity_init :: proc(s: ^State, e: Entity, time: i32) {
	w, ok := shaped_weapon(s, e.shaped_by)
	if !ok || e.owner_player < 0 || e.owner_player >= MAX_PLAYERS {
		return
	}
	p := e.owner_player
	u := unit_of(s, e)
	if u.player_projectile {
		if pct := stat_of(s, p, .Projectile_Lifetime, w).percent; pct != 0 && e.timer > 0 {
			e.timer = scale_i32(e.timer, pct)
		}
		speed := speed_from_vector(e.vel)
		if e.stationary || speed == 0 {
			return
		}
		dir := e.vel / speed
		pct := stat_of(s, p, .Initial_Projectile_Speed, w).percent
		if stat_of(s, p, .Accelerating_Projectiles, w).enabled {
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
	if e.shaped_depth != 0 || e.state < 0 || len(state_of(s, e).spawn_sets) == 0 {
		return
	}
	extra := max(stat_of(s, p, .Extra_Volley, w).extra, 0)
	pace := 100
	if pct := stat_of(s, p, .Volley_Delay, w).percent; pct != 0 {
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
spawner_volley_period :: proc "contextless" (s: ^State, e: Entity) -> (period: i32) {
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

// spawn_control for a spawner whose volleys its stats have sped up: its
// spawn sets run on their own clock, spawn_pace hundredths of a step per
// step, so a 30% shorter volley delay runs them 100/70 as fast.
paced_spawn_control :: proc(s: ^State, e: Entity) {
	e.pace_acc += e.spawn_pace
	for e.pace_acc >= 100 && !e.deleted {
		e.pace_acc -= 100
		spawn_control(s, e, e.spawn_clock)
		e.spawn_clock += 1
	}
}

// One of a shaped spawner's spawn sets firing (spawn_child). Handles its
// projectile sets -- extending the lanes and firing to the sides -- and
// returns false for the rest, which spawn as they are.
shaped_spawn_child :: proc(s: ^State, e: Entity, set: ^Spawn_Set_Def) -> bool {
	w, ok := shaped_weapon(s, e.shaped_by)
	if !ok || e.owner_player < 0 || e.owner_player >= MAX_PLAYERS || !unit_is_projectile(s, set.spawn) {
		return false
	}
	p := e.owner_player
	extra := stat_of(s, p, .Extra_Projectiles, w).extra
	side := stat_of(s, p, .Side_Firing_Volley, w).enabled
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
	emit :: proc(s: ^State, e: Entity, set: ^Spawn_Set_Def, x, y: i32, heading: i32, explicit: bool) {
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
