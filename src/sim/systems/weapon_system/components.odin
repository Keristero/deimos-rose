package weapon_system

// The components that turn on this package's entity stage, and the prefab
// builder that gives them to the units and states whose definitions ask for
// them (sim/prefabs.odin).

import "base:runtime"
import "dr:sim"

// A ground unit a player's shots can hit, and not one of theirs: what a
// ground crosshair can lock onto.
Ground_Target :: struct {}

// stateIsTargetable: a Ground_Target in the state can be locked.
Targetable :: struct {}

@(init)
register_components :: proc "contextless" () {
	context = runtime.default_context()
	sim.prefab_component_register(Ground_Target)
	sim.prefab_component_register(Targetable)
}

weapon_prefab :: proc(p: sim.Prefab, u: ^sim.Unit, st: ^sim.Unit_State) {
	if st == nil {
		if !u.harmless_to_players && u.is_ground_based && u.can_be_hit_by_player_projectile {
			sim.prefab_add(p, Ground_Target{})
		}
		return
	}
	if st.is_targetable {
		sim.prefab_add(p, Targetable{})
	}
}
