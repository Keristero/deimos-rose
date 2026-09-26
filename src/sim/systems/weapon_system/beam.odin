package weapon_system

// The Discharge Beam (a weapon with `beam.on`, docs/new-weapons.md): new
// content, not the original's, which has no instant shot. A beam is not a
// projectile. On the step it fires, a line is cast straight ahead from the
// gun, and everything a player's air shot could hit that lies across it is
// hit in order, nearest first:
//
// - the first target takes the beam's damage;
// - a target it kills explodes into shrapnel, and the damage its shields did
//   not soak carries on to the next target;
// - the beam stops at the first target left standing (or one the hit delay
//   protects), or goes off the top of the screen.
//
// The shrapnel pieces are ordinary player projectiles. Presentation draws
// the beam from `s.beams`, this step's shots, as a line that fades.

import "dr:sim"
import "dr:sim/lifecycle"
import "dr:sim/stats"
import "dr:sim/systems/collision_system"

// A kill's burst, over the enemy's own destruction effects. Provisional:
// picked by eye, the size of the largest burst in the red of the ship.
@(private = "file") BEAM_BURST :: sim.Res_ID{'l', 'a', 'r', 'g'}
@(private = "file") BEAM_BURST_COLOR :: sim.Color{0xf8, 0x60, 0x30}

@(private = "file") SITE_SHRAPNEL :: sim.Site(0xe0000020)

// Where the beam leaves the ship: the weapon's first spawn, its muzzle flash.
beam_origin :: proc "contextless" (wd: ^sim.Weapon, at: sim.Vec) -> sim.Vec {
	if len(wd.spawns) == 0 {
		return at
	}
	return at + {f32(wd.spawns[0].x_loc), f32(wd.spawns[0].y_loc)}
}

// A pulse, or a charge's release: casts the line and deals `damage` along it.
beam_fire :: proc(s: ^sim.State, h: ^sim.Weapon_Handler, wd: ^sim.Weapon, at: sim.Vec, damage, width: f32, charged: bool, time: i32) {
	from := beam_origin(wd, at)
	targets: [sim.MAX_BEAM_TARGETS]sim.Entity
	n := beam_targets(s, from, width, targets[:])
	to_y := f32(-sim.BEAM_OVERSHOOT)
	left := damage
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
		beam_explode(s, wd, loc, h.player)
		left -= before
		if left <= 0 {
			to_y = loc.y
			break
		}
	}
	q := &s.beams
	if q.count < sim.MAX_BEAM_EVENTS {
		q.events[q.count] = {from, to_y, width, charged, h.player}
		q.count += 1
	}
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

// A kill: a burst, and the shrapnel evenly spaced round from a random heading.
@(private = "file")
beam_explode :: proc(s: ^sim.State, wd: ^sim.Weapon, loc: sim.Vec, player: i32) {
	sim.particle_burst(s, loc, BEAM_BURST_COLOR, BEAM_BURST, false)
	n := wd.beam.shrapnel_count
	if wd.beam.shrapnel == sim.NONE || n <= 0 {
		return
	}
	base := sim.roll_int(s, 0, 359, SITE_SHRAPNEL)
	for k in 0 ..< n {
		req := sim.spawn_request(wd.beam.shrapnel)
		req.owner_player = player
		req.loc = loc
		req.explicit_heading = true
		req.heading = stats.wrap_angle(base + k * 360 / n)
		lifecycle.eg_request_spawn(s, req)
	}
}

// The charge's release, all at once: the release damage and width scaled by
// the power level reached against the weapon's own max, so a part charge
// deals part and Improved Charge's higher max deals more than the full.
beam_release :: proc(s: ^sim.State, h: ^sim.Weapon_Handler, wd: ^sim.Weapon, at: sim.Vec, level: i32, time: i32) {
	top := max(wd.powerup_air_max_power_level, 1)
	f := f32(level) / f32(top)
	beam_fire(s, h, wd, at, wd.beam.release_damage * f, max(wd.beam.release_width * min(f, 1), wd.beam.width), true, time)
	if wd.powerup_air_release_spawn != sim.NONE {
		lifecycle.spawn_at(s, wd.powerup_air_release_spawn, beam_origin(wd, at), h.player)
	}
}
