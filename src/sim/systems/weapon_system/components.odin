package weapon_system

// The components that turn on this package's entity stage, and the prefab
// builder that gives them to the units and states whose definitions ask for
// them (sim/prefabs.odin).

import "dr:sim"

// stateIsTargetable: a ground unit in the state that a player's shots can
// hit can be locked by a ground crosshair (sim/core has its query).
Targetable :: struct {}

register_components :: proc() {
	sim.component_register(Targetable)
}

@(init)
register_components_step :: proc "contextless" () {
	sim.register_step(.Core, "sim/systems/weapon_system register_components", register_components)
}

weapon_prefab :: proc(p: sim.Prefab, u: ^sim.Unit, st: ^sim.Unit_State) {
	sim.prefab_tag(p, st.is_targetable, Targetable)
}
