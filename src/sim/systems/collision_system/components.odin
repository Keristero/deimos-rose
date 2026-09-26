package collision_system

// The components that turn on this package's stages, and the prefab builder
// that gives them to the units and states whose definitions ask for them
// (sim/prefabs.odin). Their stages ask for them in sim/core.

import "base:runtime"
import "dr:sim"

// stateCollides: the state can touch players and be hit by shots.
Collides :: struct {}

// stateCollidesWithPlayers: touching a player in the state hurts both, or
// is a pickup collected.
Collides_With_Players :: struct {}

// harmlessToPlayers: every state of the unit is a player's shot or its kin.
Harmless_To_Players :: struct {}

// isGroundBased: every state of the unit is on the ground.
Ground_Based :: struct {}

// playerProjectile: the unit is a player's shot.
Player_Projectile :: struct {}

// canBeHitByPlayerProjectile.
Hittable_By_Player_Shots :: struct {}

// statePassHitsToOwner: hits on the entity land on its owner.
Passes_Hits_To_Owner :: struct {}

// collidesWithGroundObstacles: a ground unit that stops at wreckage, and
// (destructCreateObstacle) is wreckage itself once it has.
Blocked_By_Wreckage :: struct {
	becomes_wreckage: bool,
}

@(init)
register_components :: proc "contextless" () {
	context = runtime.default_context()
	sim.prefab_component_register(Collides)
	sim.prefab_component_register(Collides_With_Players)
	sim.prefab_component_register(Harmless_To_Players)
	sim.prefab_component_register(Passes_Hits_To_Owner)
	sim.prefab_component_register(Blocked_By_Wreckage)
	sim.prefab_component_register(Ground_Based)
	sim.prefab_component_register(Player_Projectile)
	sim.prefab_component_register(Hittable_By_Player_Shots)

	air_shot_targets = {
		with    = sim.mask_of(Collides, Hittable_By_Player_Shots),
		without = sim.mask_of(Ground_Based, Harmless_To_Players, Player_Projectile),
	}
	shot_targets = {
		with    = sim.mask_of(Collides, Hittable_By_Player_Shots),
		without = sim.mask_of(Harmless_To_Players),
	}
	ground_based = sim.mask_of(Ground_Based)
	player_projectile = sim.mask_of(Player_Projectile)
}

// What a player's air shot can hit, bar where it is (FUN_0041b920's tests
// for a player projectile in the air).
air_shot_targets: sim.Query

// What any shot can hit, before its own ground-ness and kind narrow it
// (shot_query).
@(private)
shot_targets: sim.Query
@(private)
ground_based, player_projectile: sim.Component_Mask

collision_prefab :: proc(p: sim.Prefab, u: ^sim.Unit, st: ^sim.Unit_State) {
	if st == nil {
		if u.harmless_to_players {
			sim.prefab_add(p, Harmless_To_Players{})
		}
		if u.is_ground_based {
			sim.prefab_add(p, Ground_Based{})
		}
		if u.player_projectile {
			sim.prefab_add(p, Player_Projectile{})
		}
		if u.can_be_hit_by_player_projectile {
			sim.prefab_add(p, Hittable_By_Player_Shots{})
		}
		if u.collides_with_ground_obstacles {
			sim.prefab_add(p, Blocked_By_Wreckage{becomes_wreckage = u.destruct_create_obstacle})
		}
		return
	}
	if st.collides {
		sim.prefab_add(p, Collides{})
	}
	if st.collides_with_players {
		sim.prefab_add(p, Collides_With_Players{})
	}
	if st.pass_hits_to_owner {
		sim.prefab_add(p, Passes_Hits_To_Owner{})
	}
}
