package collision_system

import "dr:blocks"
import "dr:sim"

// This package's registration results, in a block a plugin's copy is bound
// to (dr:blocks, decisions.md D83).
Shared :: struct {
	// What a player's air shot can hit, bar where it is (FUN_0041b920's
	// tests for a player projectile in the air).
	air_shot_targets:  sim.Prefab_Query,
	// What a player's air shot that hits the ground (Shaped.ground) can hit
	// there besides: air_shot_targets' counterparts on the ground.
	ground_shot_targets: sim.Prefab_Query,
	// What any shot can hit, before its own ground-ness and kind narrow it
	// (shot_hits).
	shot_targets:      sim.Prefab_Query,
	ground_based:      sim.Prefab_Query,
	player_projectile: sim.Prefab_Query,
}

@(private)
shared_block: Shared
@(private)
shared := &shared_block

@(init, private)
declare_shared :: proc "contextless" () {
	blocks.declare({name = "sim/systems/collision_system", ptr = (^rawptr)(&shared), type = Shared})
}

air_shot_targets :: #force_inline proc "contextless" () -> sim.Prefab_Query {
	return shared.air_shot_targets
}
