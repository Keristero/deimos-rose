package weapon_system

// The components that turn on this package's entity stage, and the prefab
// builder that gives them to the units and states whose definitions ask for
// them (sim/prefabs.odin).

import "base:runtime"
import "dr:sim"

// stateIsTargetable: a ground unit in the state that a player's shots can
// hit can be locked by a ground crosshair (sim/core has its query).
Targetable :: struct {}

@(init)
register_components :: proc "contextless" () {
	context = runtime.default_context()
	sim.component_register(Targetable)
}

weapon_prefab :: proc(p: sim.Prefab, u: ^sim.Unit, st: ^sim.Unit_State) {
	if st.is_targetable {
		sim.prefab_add(p, Targetable{})
	}
}
