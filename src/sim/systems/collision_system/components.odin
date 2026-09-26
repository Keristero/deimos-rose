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
}

collision_prefab :: proc(p: sim.Prefab, u: ^sim.Unit, st: ^sim.Unit_State) {
	if st == nil {
		if u.harmless_to_players {
			sim.prefab_add(p, Harmless_To_Players{})
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
