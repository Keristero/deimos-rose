package new_weapon_passives

import "dr:blocks"
import "dr:plugins/passives"
import "dr:sim"

// This plugin's registration results, in a block a plugin's copy of this
// package is bound to (dr:blocks, decisions.md D83).
Shared :: struct {
	id:              sim.Plugin_ID,
	weapon_5:        passives.Passive,
	weapon_6:        passives.Passive,
	weapon_5_charge: passives.Passive,
	weapon_6_charge: passives.Passive,
}

@(private)
shared_block: Shared
@(private)
shared := &shared_block

@(init, private)
declare_shared :: proc "contextless" () {
	blocks.declare({name = "plugins/new_weapon_passives", ptr = (^rawptr)(&shared), type = Shared})
}

id :: #force_inline proc "contextless" () -> sim.Plugin_ID {
	return shared.id
}

weapon_5 :: #force_inline proc "contextless" () -> passives.Passive {
	return shared.weapon_5
}

weapon_6 :: #force_inline proc "contextless" () -> passives.Passive {
	return shared.weapon_6
}

weapon_5_charge :: #force_inline proc "contextless" () -> passives.Passive {
	return shared.weapon_5_charge
}

weapon_6_charge :: #force_inline proc "contextless" () -> passives.Passive {
	return shared.weapon_6_charge
}
