package movement_system

// The components that turn on this package's stages, and the prefab builder
// that gives them to the units and states whose definitions ask for them
// (sim/prefabs.odin). Their stages ask for them in sim/core.

import "base:runtime"
import "dr:sim"

// stateDeleteOnNoActivePlayers: deleted when no player is in play.
Deleted_Without_Players :: struct {}

// stateDestructOnNoActivePlayers: destroyed when no player is in play.
Destructs_Without_Players :: struct {}

// fleesNorth/SouthOnNoActivePlayers: every state of the unit flees when no
// player is in play, to `flee` (lifecycle.entity_flee). North wins where a
// definition sets both, as it does in the original's test order.
Flees_Without_Players :: struct {
	flee: sim.Res_ID,
}

// stateCyclicMotion: wander (cyclic_motion).
Cyclic_Motion :: struct {}

// constrainInGameArea: every state of the unit bounces off the edges of the
// play area.
Constrained_To_Play_Area :: struct {}

// stateLockToOwnerLoc, stateLinkToOwnerLoc and stateOrbitOwner: the ways an
// entity follows its owner.
Locked_To_Owner :: struct {}
Linked_To_Owner :: struct {}
Orbits_Owner :: struct {}

@(init)
register_components :: proc "contextless" () {
	context = runtime.default_context()
	sim.component_register(Deleted_Without_Players)
	sim.component_register(Destructs_Without_Players)
	sim.component_register(Flees_Without_Players)
	sim.component_register(Cyclic_Motion)
	sim.component_register(Constrained_To_Play_Area)
	sim.component_register(Locked_To_Owner)
	sim.component_register(Linked_To_Owner)
	sim.component_register(Orbits_Owner)
}

// A state's components, from the flags its unit's and its own definitions
// set.
movement_prefab :: proc(p: sim.Prefab, u: ^sim.Unit, st: ^sim.Unit_State) {
	if u.flees_north_on_no_active_players {
		sim.prefab_add(p, Flees_Without_Players{sim.res_id("nora")})
	} else if u.flees_south_on_no_active_players {
		sim.prefab_add(p, Flees_Without_Players{sim.res_id("sora")})
	}
	sim.prefab_tag(p, u.constrain_in_game_area, Constrained_To_Play_Area)
	sim.prefab_tag(p, st.delete_on_no_active_players, Deleted_Without_Players)
	sim.prefab_tag(p, st.destruct_on_no_active_players, Destructs_Without_Players)
	sim.prefab_tag(p, st.cyclic_motion, Cyclic_Motion)
	sim.prefab_tag(p, st.lock_to_owner_loc, Locked_To_Owner)
	sim.prefab_tag(p, st.link_to_owner_loc, Linked_To_Owner)
	sim.prefab_tag(p, st.orbit_owner, Orbits_Owner)
}
