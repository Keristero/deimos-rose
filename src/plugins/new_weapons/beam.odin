package new_weapons

// The Discharge Beam (a weapon with x_Beam_BOOL, docs/new-weapons.md): new
// content, not the original's, which has no instant shot. A beam is not a
// projectile. A press winds up first (Weapon_Fire.windup): the weapon's own
// spawn, the precharge, plays while it does. Then, on the step it fires, a
// line is cast straight ahead from the gun, and everything a player's air
// shot could hit that lies across it is hit in order, nearest first:
//
// - the first target takes the beam's damage;
// - a target it kills bursts, and the damage its shields did not soak
//   carries on to the next target;
// - the beam stops at the first target left standing (or one the hit delay
//   protects), or goes off the top of the screen.
//
// A charged beam leaves motes along its path, ordinary units that linger
// and then burst into fragments, player projectiles. Each shot is pushed
// as a Beam_Event (sim/queue_effects.odin), and kept in the session's
// Beam_Log for the view, which draws it as a line that fades.
//
// The log is why the other player's beams show in netplay. The beam does
// not auto-repeat: every pulse is a new press and a charge fires on
// release, so the peer's prediction (the last buttons it had) never
// guesses one, and the step that fires it is always one a rollback
// replays. Effect events are read only after the newest step, so a replayed
// step's are gone; the log is state, rolled back and replayed with the
// rest.

import "dr:sim"
import "dr:sim/lifecycle"
import "dr:sim/stats"
import "dr:sim/systems/collision_system"

// Steps from a press to its pulse.
beam_windup :: proc "contextless" (wd: ^sim.Weapon) -> i32 {
	return sim.weapon_int(wd, BEAM_WINDUP)
}

// A pulse: once a press has wound up, with its muzzle flash.
beam_shot :: proc(s: ^sim.State, h: ^sim.Weapon_Handler, wd: ^sim.Weapon, at: sim.Vec, time: i32) {
	b := beam_def(wd)
	if b.flash != sim.NONE {
		lifecycle.spawn_at(s, b.flash, beam_origin(wd, at), h.player)
	}
	beam_fire(s, h, wd, at, b.damage, b.width, false, time)
}

// A kill's burst, over the enemy's own destruction effects. Provisional:
// picked by eye, the size of the largest burst in the red of the ship.
@(private = "file") BEAM_BURST :: sim.Res_ID{'l', 'a', 'r', 'g'}
@(private = "file") BEAM_BURST_COLOR :: sim.Color{0xf8, 0x60, 0x30}

// The most targets one beam can pass through. A full screen of the densest
// formation (Shuriken, groups of 11) in one column is well under this.
MAX_BEAM_TARGETS :: 64

// How far above the top of the screen an unstopped beam is drawn to.
BEAM_OVERSHOOT :: 16

// A beam's shot, for the view to draw.
Beam_Event :: struct {
	from:    sim.Vec, // the gun
	to_y:    f32, // where it stopped; above the screen if nothing stopped it
	width:   f32,
	charged: bool,
	player:  i32,
	time:    i32, // the level step it fired on
	level:   i32, // Level_Info.played when it fired
}

// The most recent beams, on the session entity, oldest overwritten first.
// Enough for every beam still fading: two players, a pulse a step at most,
// over the longest fade (the view's, 12 steps).
MAX_RECENT_BEAMS :: 32
Beam_Log :: struct {
	events: [MAX_RECENT_BEAMS]Beam_Event,
	next:   i32,
}

beam_log_of :: #force_inline proc "contextless" (s: ^sim.State) -> ^Beam_Log {
	return sim.single(s, Beam_Log)
}

// The weapon's settings: new keys on its definition.
Beam_Def :: struct {
	damage:         f32, // a pulse's
	width:          f32, // px across the line that a target's circle must touch
	release_damage: f32, // a charge's at the weapon's own max power level
	release_width:  f32,
	flash:          sim.Res_ID, // spawned at the gun as a pulse fires
	// A charged beam's motes: one every mote_spacing px along it, bursting
	// mote_delay_min steps after it fired, and up to mote_delay_max more
	// for a full charge. One of each release is mote_sounded, which plays
	// the burst.
	mote:           sim.Res_ID,
	mote_sounded:   sim.Res_ID,
	mote_spacing:   i32,
	mote_delay_min: i32,
	mote_delay_max: i32,
}

beam_def :: proc "contextless" (wd: ^sim.Weapon) -> Beam_Def {
	return {
		damage         = sim.weapon_float(wd, BEAM_DAMAGE),
		width          = sim.weapon_float(wd, BEAM_WIDTH),
		release_damage = sim.weapon_float(wd, BEAM_RELEASE_DAMAGE),
		release_width  = sim.weapon_float(wd, BEAM_RELEASE_WIDTH),
		flash          = sim.weapon_id(wd, BEAM_FLASH),
		mote           = sim.weapon_id(wd, BEAM_MOTE),
		mote_sounded   = sim.weapon_id(wd, BEAM_MOTE_SOUNDED),
		mote_spacing   = sim.weapon_int(wd, BEAM_MOTE_SPACING),
		mote_delay_min = sim.weapon_int(wd, BEAM_MOTE_DELAY_MIN),
		mote_delay_max = sim.weapon_int(wd, BEAM_MOTE_DELAY_MAX),
	}
}

// This step's beams, in the order they fired.
beam_shots :: proc(s: ^sim.State, allocator := context.temp_allocator) -> []Beam_Event {
	out := make([dynamic]Beam_Event, allocator)
	walk := sim.effects_of(s, BEAM_SHOT, Beam_Event)
	for ev in sim.effects_next(&walk) {
		append(&out, ev)
	}
	return out[:]
}

// Where the beam leaves the ship: the weapon's first spawn, its precharge.
beam_origin :: proc "contextless" (wd: ^sim.Weapon, at: sim.Vec) -> sim.Vec {
	if len(wd.spawns) == 0 {
		return at
	}
	return at + {f32(wd.spawns[0].x_loc), f32(wd.spawns[0].y_loc)}
}

// A pulse, or a charge's release: casts the line and deals `damage` along
// it, both scaled by the weapon's stats for the player (beam_scaled).
// Returns where it stopped.
beam_fire :: proc(s: ^sim.State, h: ^sim.Weapon_Handler, wd: ^sim.Weapon, at: sim.Vec, damage, width: f32, charged: bool, time: i32) -> (to_y: f32) {
	left, wide := beam_scaled(s, h, damage, width)
	from := beam_origin(wd, at)
	targets: [MAX_BEAM_TARGETS]sim.Entity
	n := beam_targets(s, from, wide, targets[:])
	to_y = -BEAM_OVERSHOOT
	for e in targets[:n] {
		if e.deleted {
			// Kills are only marked here and swept after the step, so nothing
			// the beam hits deletes another target on the line; kept in case
			// a hit ever does.
			continue
		}
		loc := e.loc
		before := e.shields
		collision_system.entity_hit(s, e, left, h.player, time)
		if !e.deleted && e.shields > 0 {
			to_y = loc.y // it stands, or the hit delay turned the beam away
			break
		}
		sim.particle_burst(s, loc, BEAM_BURST_COLOR, BEAM_BURST, false)
		left -= before
		if left <= 0 {
			to_y = loc.y
			break
		}
	}
	ev := Beam_Event{from, to_y, wide, charged, h.player, time, sim.single(s, sim.Level_Info).played}
	sim.effect_push(s, BEAM_SHOT, ev)
	if log := beam_log_of(s); log != nil {
		log.events[log.next] = ev
		log.next = (log.next + 1) % MAX_RECENT_BEAMS
	}
	return
}

// A beam's damage and width for the player firing it: the damage stat
// scales both, the width by its percentage added to the width stat's
// (notes/extra-weapon-passives-and-base-adjustments.md: "width also scales
// with damage"). Unchanged with no provider on.
beam_scaled :: proc "contextless" (s: ^sim.State, h: ^sim.Weapon_Handler, damage, width: f32) -> (f32, f32) {
	dmg := stats.weapon_stat(s, h.player, h.air.weapon, .Projectile_Damage).percent
	wide := stats.weapon_stat(s, h.player, h.air.weapon, .Shot_Width).percent
	return stats.scale_f32(damage, dmg), stats.scale_f32(width, dmg + wide)
}

// Everything across the line from `from` straight up that the beam can hit,
// nearest first: a target's hit circle (entity_collisions' radius) within
// half the width of the line, its centre ahead of the gun, and on screen.
beam_targets :: proc "contextless" (s: ^sim.State, from: sim.Vec, width: f32, out: []sim.Entity) -> int {
	n := 0
	walk := sim.walk_entities(s)
	for e in sim.walk_next(&walk) {
		if n >= len(out) || !air_shot_can_hit(s, e) || e.shields <= 0 {
			continue
		}
		b := lifecycle.object_bounds(e.obj)
		r := f32(lifecycle.halve(b.bottom - b.top))
		if abs(e.loc.x - from.x) > r + width / 2 || e.loc.y >= from.y || e.loc.y + r < 0 {
			continue
		}
		// Insertion by distance, then by number, so the order is the
		// same however the groups are linked.
		j := n
		for j > 0 && beam_before(e, out[j - 1]) {
			out[j] = out[j - 1]
			j -= 1
		}
		out[j] = e
		n += 1
	}
	return n
}

@(private = "file")
beam_before :: proc "contextless" (a, b: sim.Entity) -> bool {
	if a.loc.y != b.loc.y {
		return a.loc.y > b.loc.y
	}
	return a.number < b.number
}

// The charge's release, all at once, however many levels it holds: the
// release damage and width scaled by the power level reached against the
// weapon's own max, so a part charge deals part and Improved Charge's
// higher max deals more than the full.
beam_release :: proc(s: ^sim.State, h: ^sim.Weapon_Handler, wd: ^sim.Weapon, at: sim.Vec, level: i32, time: i32) {
	b := beam_def(wd)
	top := max(wd.powerup_air_max_power_level, 1)
	f := f32(level) / f32(top)
	to_y := beam_fire(s, h, wd, at, b.release_damage * f, max(b.release_width * min(f, 1), b.width), true, time)
	beam_motes(s, h, wd, beam_origin(wd, at), to_y, f)
	if wd.powerup_air_release_spawn != sim.NONE {
		lifecycle.spawn_at(s, wd.powerup_air_release_spawn, beam_origin(wd, at), h.player)
	}
}

// The most motes one charged beam leaves: a full screen's height at the
// shipped spacing is well under this.
MAX_BEAM_MOTES :: 24

// A charged beam's motes, one every mote_spacing px along it from the gun
// to where it stopped (the top of the screen at most), nearest first. They
// drift in a random direction (the unit's initialHeadingTolerance) and
// burst together, later the fuller the charge (`f`, the level against the
// weapon's max). Their fragments count as the weapon's shots
// (shot_shaper), so its passives shape them.
beam_motes :: proc(s: ^sim.State, h: ^sim.Weapon_Handler, wd: ^sim.Weapon, from: sim.Vec, to_y: f32, f: f32) {
	b := beam_def(wd)
	if b.mote == sim.NONE || b.mote_spacing <= 0 {
		return
	}
	delay := b.mote_delay_min + stats.round_i32(f32(b.mote_delay_max - b.mote_delay_min) * f)
	tag := stats.shot_shaper(s, h.player, h.air.weapon)
	top := max(to_y, 0)
	y := from.y - f32(b.mote_spacing) / 2
	for k := 0; k < MAX_BEAM_MOTES && y > top; k += 1 {
		req := sim.spawn_request(k == 0 && b.mote_sounded != sim.NONE ? b.mote_sounded : b.mote)
		req.owner_player = h.player
		req.loc = {from.x, y}
		req.explicit_heading = true
		req.shaped_by = tag
		// Its fragments are spawned by a spawner the weapon did not fire:
		// they take its damage, not its lanes (shaped_spawn_child).
		req.shaped_depth = 1
		ref := lifecycle.eg_request_spawn(s, req)
		if ref.index != sim.NO_LINK && delay > 0 {
			sim.entity_at(s, ref.index).timer = delay
		}
		y -= f32(b.mote_spacing)
	}
}
