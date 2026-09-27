package new_weapons

import "dr:sim"
import "dr:sim/systems/collision_system"

// Whether a player's air shot can hit `e`: the candidates entity_collisions
// would test a player projectile against, bar the overlap itself. For the
// new weapons that find their targets themselves: the Discharge Beam's
// line, and the Chaingun's aim (plugins/chaingun).
air_shot_can_hit :: proc "contextless" (s: ^sim.State, e: sim.Entity) -> bool {
	if e.deleted || !e.hittable || e.state < 0 || e.appear_delay >= 1 {
		return false
	}
	return sim.prefab_is(s, sim.prefab_of(s, e), collision_system.air_shot_targets)
}
