package chaingun

import "dr:blocks"
import "dr:sim"

// This plugin's registration results, in a block a plugin's copy of this
// package is bound to (dr:blocks, decisions.md D83).
Shared :: struct {
	id:            sim.Plugin_ID,
	aimed_release: sim.Weapon_Key, // the charge fires aimed volleys at the nearest enemy (sim/def_keys.odin)
}

@(private)
shared_block: Shared
@(private)
shared := &shared_block

@(init, private)
declare_shared :: proc "contextless" () {
	blocks.declare({name = "plugins/chaingun", ptr = (^rawptr)(&shared), type = Shared})
}

id :: #force_inline proc "contextless" () -> sim.Plugin_ID {
	return shared.id
}

aimed_release :: #force_inline proc "contextless" () -> sim.Weapon_Key {
	return shared.aimed_release
}
