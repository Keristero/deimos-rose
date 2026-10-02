package stats

// Stats: the numbers the core's mechanics read that a plugin may change --
// how fast a ship accelerates, how a weapon charges, fires and what its
// shots do -- and the mechanics that follow them where the original has
// none (extra lanes and volleys, paced charging, shaped shots). Plugins
// supply the changes through stat providers (sim/hooks.odin), passive
// upgrades (plugins/passives) among them.
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
// classic mode, run none. No systems: the systems that use a stat ask for it
// here.

import "dr:sim"

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
player_stat :: #force_inline proc "contextless" (s: ^sim.State, player: i32, stat: sim.Stat, weapon: sim.Res_ID = sim.NONE) -> sim.Stat_Total {
	return sim.stat_of(s, player, stat, weapon)
}

// A weapon stat for the weapon at index `weapon` in Defs.weapons: for its
// shots, or with `charge` for its charge (sim.Stat_Provider).
weapon_stat :: proc "contextless" (s: ^sim.State, player: i32, weapon: i32, stat: sim.Stat, charge := false) -> sim.Stat_Total {
	if weapon == sim.NO_WEAPON || player < 0 {
		return {}
	}
	return sim.stat_of(s, player, stat, s.defs.weapons[weapon].id, charge)
}

// A stat of the weapon's charge: how it climbs, and what its release fires.
charge_stat :: #force_inline proc "contextless" (s: ^sim.State, player: i32, weapon: i32, stat: sim.Stat) -> sim.Stat_Total {
	return weapon_stat(s, player, weapon, stat, true)
}

// Shots carry the weapon that fired them when a provider shapes it, so that
// they can be shaped after they spawn (Shaped): 0 for none, else the
// weapon's index + 1. What a shaped spawner spawns carries it too.
shot_shaper :: proc "contextless" (s: ^sim.State, player: i32, weapon: i32, charge := false) -> u8 {
	if weapon == sim.NO_WEAPON || player < 0 || !sim.stat_shapes(s, player, s.defs.weapons[weapon].id, charge) {
		return 0
	}
	return u8(weapon + 1)
}

// Tags a spawn as `player`'s shot of `weapon`, or with `charge` of its
// charge's release, when a provider shapes those. Untouched otherwise.
shape_spawn :: proc "contextless" (s: ^sim.State, req: ^sim.Spawn_Request, player: i32, weapon: i32, charge := false) {
	req.shaped_by = shot_shaper(s, player, weapon, charge)
	req.shaped_charge = charge && req.shaped_by != 0
}

// The weapon a shaped entity's stats are read for.
shaped_weapon :: #force_inline proc "contextless" (s: ^sim.State, shaped_by: u8) -> (sim.Res_ID, bool) {
	if shaped_by == 0 {
		return sim.NONE, false
	}
	return s.defs.weapons[shaped_by - 1].id, true
}

// A stat for a shot as it was tagged (shape_spawn): its weapon's, for the
// player who fired it, in its scope. ok is false, and the stat zero, for a
// shot no provider shaped.
shaped_stat_of :: proc "contextless" (s: ^sim.State, player: i32, shaped_by: u8, charge: bool, stat: sim.Stat) -> (t: sim.Stat_Total, ok: bool) {
	w: sim.Res_ID
	w, ok = shaped_weapon(s, shaped_by)
	if !ok || player < 0 || player >= sim.MAX_PLAYERS {
		return {}, false
	}
	return sim.stat_of(s, player, stat, w, charge), true
}

// A stat for a shaped entity (shaped_stat_of).
shaped_stat :: #force_inline proc "contextless" (s: ^sim.State, e: sim.Entity, stat: sim.Stat) -> sim.Stat_Total {
	t, _ := shaped_stat_of(s, e.owner_player, e.shaped_by, e.shaped_charge, stat)
	return t
}

@(private = "file") PF_STEP_HZ :: 0x20

// Game steps a second.
step_hz :: #force_inline proc "contextless" (s: ^sim.State) -> i32 {
	return max(sim.trunc_i32(s.defs.perm_floats[PF_STEP_HZ]), 1)
}

// The ship.

// active_velocity_delta, scaled by Maneuverability.
player_acceleration :: proc "contextless" (s: ^sim.State, p: sim.Player, base: f32) -> f32 {
	return scale_f32(base, player_stat(s, p.number, .Maneuverability).percent)
}


// For presentation: how far an air charge has climbed past the weapon's own
// maximum, 0 at or below it and 1 at the raised one.
player_overcharge :: proc "contextless" (s: ^sim.State, p: sim.Player) -> f32 {
	h := p.weapons
	if h.air_powerup.state != 1 && h.air_powerup.state != 2 || h.air.weapon == sim.NO_WEAPON {
		return 0
	}
	base := sim.weapon_def(s, h.air.weapon).powerup_air_max_power_level
	top := powerup_max_level(s, h, h.air.weapon)
	if top <= base || h.air_powerup.level <= base {
		return 0
	}
	return min(f32(h.air_powerup.level - base) / f32(top - base), 1)
}

// Charging.

// Whether the air weapon charges without the button: Auto Charge, on a
// weapon with a power-up at all.
air_auto_charge :: proc "contextless" (s: ^sim.State, h: ^sim.Weapon_Handler) -> bool {
	if h.air.weapon == sim.NO_WEAPON || !player_stat(s, h.player, .Auto_Charge_Air_To_Air).enabled {
		return false
	}
	wd := sim.weapon_def(s, h.air.weapon)
	return !wd.auto_repeat && (wd.powerup_air_activation_spawn != sim.NONE || wd.powerup_air_release_spawn != sim.NONE)
}

powerup_max_level :: proc "contextless" (s: ^sim.State, h: ^sim.Weapon_Handler, weapon: i32) -> i32 {
	base := sim.weapon_def(s, weapon).powerup_air_max_power_level
	return scale_i32(base, charge_stat(s, h.player, weapon, .Maximum_Charge).percent)
}

// powerup_air_overload_time, or 0 (never) under Prevent_Overheat.
powerup_overload_time :: proc "contextless" (s: ^sim.State, h: ^sim.Weapon_Handler, weapon: i32) -> i32 {
	base := sim.weapon_def(s, weapon).powerup_air_overload_time
	if charge_stat(s, h.player, weapon, .Prevent_Overheat).enabled {
		return 0
	}
	return scale_i32(base, charge_stat(s, h.player, weapon, .Overheat_Delay).percent)
}

// Whether a charging power-up climbs a level this step. The original climbs
// once every between + 1 steps (level_time + between < time); a changed
// Charge_Rate keeps pace in hundredths of a step instead, since a 10%
// change to a 2-step interval would otherwise round away.
powerup_level_due :: proc "contextless" (s: ^sim.State, h: ^sim.Weapon_Handler, p: ^sim.Powerup, weapon: i32, time: i32) -> bool {
	between := sim.weapon_def(s, weapon).powerup_air_time_between_power_level_changes
	pct := charge_stat(s, h.player, weapon, .Charge_Rate).percent
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

// Whether a releasing power-up's next spawn is due. The original fires one
// every between + 1 steps (release_time + between < time), the first as
// soon as it lets go. Release_Ramp keeps pace in hundredths after the
// first, each spawn already fired adding its percentage to the pace, so
// the release fires faster as it goes: up to one every sim.hit_gap steps,
// the most hits one target takes. Faster, the Chaingun's ramp measured
// 20% less DPS in every DPS report scenario: the shots past one target's
// hits were wasted, and the release spent sooner.
powerup_release_due :: proc "contextless" (s: ^sim.State, h: ^sim.Weapon_Handler, p: ^sim.Powerup, weapon: i32, time: i32) -> bool {
	between := sim.weapon_def(s, weapon).powerup_air_time_between_release_spawns
	pct := charge_stat(s, h.player, weapon, .Release_Ramp).percent
	if pct == 0 || p.released == 0 {
		return p.release_time + between < time
	}
	need := (between + 1) * 100
	p.pace += clamp(100 + pct * p.released, 1, max(need / sim.hit_gap(s), 100))
	if p.pace < need {
		return false
	}
	p.pace -= need
	return true
}

// Firing.

// delay_between_launches, scaled by Firing_Delay.
air_firing_delay :: proc "contextless" (s: ^sim.State, h: ^sim.Weapon_Handler, weapon: i32) -> i32 {
	return scale_i32(sim.weapon_def(s, weapon).delay_between_launches, weapon_stat(s, h.player, weapon, .Firing_Delay).percent)
}

// Steps between the extra volleys of a direct-fire shot (one whose spawn
// list holds its projectiles, not a spawner of them), before Volley_Delay.
// Provisional: no original weapon fires volleys this way to measure; two
// steps is the gap the Rear Gun's and Photon Beam's own spawners leave.
VOLLEY_INTERVAL :: 2

// After a direct-fire shot: the extra volleys it owes, fired one per
// (scaled) VOLLEY_INTERVAL. A spawner weapon's volleys come from its
// spawner instead -- see shaped_entity_init.
air_volleys_schedule :: proc "contextless" (s: ^sim.State, h: ^sim.Weapon_Handler) {
	h.volleys_left, h.volley_pace = 0, 0
	if !weapon_is_direct(s, h.air.weapon) {
		return
	}
	h.volleys_left = max(weapon_stat(s, h.player, h.air.weapon, .Extra_Volley).extra, 0)
}

// Whether an owed volley is due this step.
air_volley_due :: proc "contextless" (s: ^sim.State, h: ^sim.Weapon_Handler) -> bool {
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
ground_burst_due :: proc "contextless" (s: ^sim.State, h: ^sim.Weapon_Handler, time: i32) -> bool {
	gw := sim.weapon_def(s, h.ground.weapon)
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

// The ground weapon's charge (Ground_Charge), which the original does not
// have: its one ground weapon has no power-up. Fire-ground held on past
// the burst a press fires charges one more volley, aimed by the
// crosshair, which may turn about the ship meanwhile; letting go once it
// is ready drops it. Its stats are the charge's (charge_stat), so a
// passive can make that volley heavier without touching the burst.

// Steps fire-ground is held before the charge begins. Provisional: the
// air weapons' own powerup_air_time_until_activation.
GROUND_CHARGE_HOLD :: 15

// Steps the charge is held before letting go drops it; let go sooner, it
// is lost. Without it a heavy volley dropped the moment the charge began,
// straight ahead, outdid the burst it was added to: the DPS report's
// first runs. Half a second: provisional, the time the crosshair takes to
// swing round behind (CHARGE_SWING_DEGREES_A_SECOND), so that charge is
// ready as it gets there.
ground_charge_ready :: #force_inline proc "contextless" (s: ^sim.State) -> i32 {
	return step_hz(s) / 2
}

// How fast the crosshair turns while charged. Provisional: picked to
// swing round behind in half a second, and to circle the ship in two.
CHARGE_SWING_DEGREES_A_SECOND :: 360
CHARGE_ORBIT_DEGREES_A_SECOND :: 180

// Whether the ground weapon charges: Ground_Charge, on a weapon without a
// power-up of its own in its data (which is the original's, unported).
ground_charges :: proc "contextless" (s: ^sim.State, h: ^sim.Weapon_Handler) -> bool {
	if h.ground.weapon == sim.NO_WEAPON {
		return false
	}
	gw := sim.weapon_def(s, h.ground.weapon)
	if gw.powerup_ground_activation_spawn != sim.NONE || gw.powerup_ground_release_spawn != sim.NONE {
		return false
	}
	return charge_stat(s, h.player, h.ground.weapon, .Ground_Charge).enabled
}

// Where a charged crosshair has turned to a step on: round behind the ship
// and held there (Charge_Aim_Behind), or on round it (Charge_Aim_Around).
ground_aim_next :: proc "contextless" (s: ^sim.State, h: ^sim.Weapon_Handler) -> i32 {
	if charge_stat(s, h.player, h.ground.weapon, .Charge_Aim_Around).enabled {
		return wrap_angle(h.ground_aim + max(CHARGE_ORBIT_DEGREES_A_SECOND / step_hz(s), 1))
	}
	if charge_stat(s, h.player, h.ground.weapon, .Charge_Aim_Behind).enabled {
		return min(h.ground_aim + max(CHARGE_SWING_DEGREES_A_SECOND / step_hz(s), 1), 180)
	}
	return h.ground_aim
}

// Where a crosshair `ahead` px in front of the ship and `x` px to its
// right stands once turned `turn` degrees about it. It goes round on an
// ellipse: the full reach ahead, three quarters of it to the sides, and
// half of it behind, as there is less room behind the ship than ahead.
crosshair_turned :: proc "contextless" (ship: sim.Vec, x, ahead: f32, turn: i32) -> sim.Vec {
	reach := ahead * (3 + sim.m_cos(wrap_angle(turn))) / 4
	return ship + turn_offset({x, -reach}, turn)
}

// An offset from the ship, turned `turn` degrees clockwise on screen: the
// way a heading of `turn` faces.
turn_offset :: proc "contextless" (v: sim.Vec, turn: i32) -> sim.Vec {
	t := wrap_angle(turn)
	c, sn := sim.m_cos(t), sim.m_sin(t)
	return {v.x * c - v.y * sn, v.x * sn + v.y * c}
}

// A weapon is direct-fire when its spawn list holds player projectiles
// itself; otherwise it spawns a spawner of them (the Rear Gun, the Photon
// Beam), whose own spawn sets are the lanes.
weapon_is_direct :: proc "contextless" (s: ^sim.State, weapon: i32) -> bool {
	for &sp in sim.weapon_def(s, weapon).spawns {
		if unit_is_projectile(s, sp.unit) {
			return true
		}
	}
	return false
}

unit_is_projectile :: proc "contextless" (s: ^sim.State, id: sim.Res_ID) -> bool {
	if id == sim.NONE {
		return false
	}
	ui := sim.unit_index(s.defs, id)
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
	t := f32(sim.trunc_i32(v))
	return t > v ? t - 1 : t
}

// Nearest whole, halves away from zero.
round_i32 :: proc "contextless" (v: f32) -> i32 {
	return v < 0 ? -sim.trunc_i32(-v + 0.5) : sim.trunc_i32(v + 0.5)
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

// A weapon's spawn list, shaped by its passive (by its charge's, with
// `charge`): the lanes extended, and every spawn turned `turn` degrees
// about the ship, as a charged ground weapon's are with its crosshair.
// Non-projectile entries (muzzle flashes, spawners) fire as they are.
Weapon_Spawn :: struct {
	unit:        sim.Res_ID,
	x, y:        i32,
	set_heading: bool,
	angle:       i32,
}

weapon_spawns :: proc "contextless" (s: ^sim.State, weapon: i32, player: i32, out: []Weapon_Spawn, charge := false, turn: i32 = 0) -> int {
	wd := sim.weapon_def(s, weapon)
	extra := weapon_stat(s, player, weapon, .Extra_Projectiles, charge).extra
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
	push :: proc "contextless" (out: []Weapon_Spawn, count: ^int, sp: Weapon_Spawn, turn: i32) {
		if count^ >= len(out) {
			return
		}
		sp := sp
		if turn != 0 {
			at := turn_offset({f32(sp.x), f32(sp.y)}, turn)
			sp.x, sp.y = round_i32(at.x), round_i32(at.y)
			sp.set_heading = true
			sp.angle = wrap_angle(sp.angle + turn)
		}
		out[count^] = sp
		count^ += 1
	}
	lanes_done := false
	for &sp in wd.spawns {
		if sp.unit == sim.NONE {
			continue
		}
		if m == 0 || !unit_is_projectile(s, sp.unit) {
			push(out, &count, {sp.unit, sp.x_loc, sp.y_loc, sp.set_heading, sp.angle}, turn)
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
			push(out, &count, {src.unit, round_i32(l.x), round_i32(l.y), src.set_heading || a != 0, wrap_angle(a)}, turn)
		}
	}
	return count
}

// A shaped shot's initialHeadingTolerance, scaled by its weapon's
// Random_Spread_Range, and at most a full turn. 0 stays 0, so a unit that
// flies straight draws nothing more.
heading_tolerance :: proc "contextless" (s: ^sim.State, owner_player: i32, shaped_by: u8, charge: bool, base: i32) -> i32 {
	t, ok := shaped_stat_of(s, owner_player, shaped_by, charge, .Random_Spread_Range)
	if !ok || base == 0 {
		return base
	}
	return min(scale_i32(base, t.percent), 360)
}

// Shaped entities.

// The damage a shaped shot deals, scaled by its weapon's Projectile_Damage.
// What it spawns is shaped too (a bomb's blast), so that is scaled as well.
shot_damage :: proc "contextless" (s: ^sim.State, e: sim.Entity, base: f32) -> f32 {
	return scale_f32(base, shaped_stat(s, e, .Projectile_Damage).percent)
}

// Accelerating shots leave at the scaled initial speed and speed up evenly
// until they are back to their unit's own speed ACCEL_SECONDS later
// (notes/extra-weapon-passives-and-base-adjustments.md: "only get back to
// the original speed after about 1 second").
ACCEL_SECONDS :: 1

// Right after a shaped entity spawns (spawn_entity): its weapon's stats
// shape it. A projectile's flight (lifetime, speed); a spawner fired
// straight from the weapon (depth 0) its volleys.
shaped_entity_init :: proc(s: ^sim.State, e: sim.Entity, time: i32) {
	if _, ok := shaped_weapon(s, e.shaped_by); !ok || e.owner_player < 0 || e.owner_player >= sim.MAX_PLAYERS {
		return
	}
	u := sim.unit_of(s, e)
	if u.player_projectile {
		if pct := shaped_stat(s, e, .Projectile_Lifetime).percent; pct != 0 && e.timer > 0 {
			e.timer = scale_i32(e.timer, pct)
		}
		speed := sim.speed_from_vector(e.vel)
		if e.stationary || speed == 0 {
			return
		}
		dir := e.vel / speed
		pct := shaped_stat(s, e, .Initial_Projectile_Speed).percent
		if shaped_stat(s, e, .Accelerating_Projectiles).enabled {
			start := scale_f32(speed, pct)
			e.vel = dir * start
			e.vel_target = dir * speed
			e.vel_delta = dir * (abs(speed - start) / f32(ACCEL_SECONDS * step_hz(s)))
			e.vel_prev = e.vel
		} else if pct != 0 {
			e.vel = dir * scale_f32(speed, pct)
			e.vel_target = e.vel
			e.vel_prev = e.vel
		}
		return
	}
	if e.shaped_depth != 0 || e.state < 0 || len(sim.state_of(s, e).spawn_sets) == 0 {
		return
	}
	extra := max(shaped_stat(s, e, .Extra_Volley).extra, 0)
	pace := 100
	if pct := shaped_stat(s, e, .Volley_Delay).percent; pct != 0 {
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
spawner_volley_period :: proc "contextless" (s: ^sim.State, e: sim.Entity) -> (period: i32) {
	period = 1
	for &set in sim.state_of(s, e).spawn_sets {
		if !unit_is_projectile(s, set.spawn) {
			continue
		}
		p := set.repeat_spawns ? set.rate_max + 1 : set.delay_between_entities_max
		period = max(period, p)
	}
	return
}
