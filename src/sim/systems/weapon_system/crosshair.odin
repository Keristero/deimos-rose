package weapon_system

// The crosshair's stage of G_EG_Process: a ground target under it locks
// it.

import "dr:sim"

// A ground target under a player's crosshair locks it, which turns it from
// its normal frame to the locked one (red for "plbo"). G_EG_Process 0x418220
// tests each player in play whose crosshair is not locked yet this step
// against the bounds taken after SpawnControl: left <= x < right,
// top <= y < bottom. weapons_process unlocks it again every step.
// Entities with Ground_Target and Targetable.
crosshair_lock_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	b := es.bounds
	for p in sim.players_of(s) {
		if p.state != .Playing || p.weapons.crosshair_locked {
			continue
		}
		c := p.weapons.crosshair.loc
		if f32(b.left) <= c.x && c.x < f32(b.right) && f32(b.top) <= c.y && c.y < f32(b.bottom) {
			crosshair_hilite(s, p.weapons, true)
		}
	}
	return true
}
