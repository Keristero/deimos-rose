package extra_prefs

import "dr:blocks"
import "dr:sim"

// This plugin's registration results, in a block a plugin's copy of this
// package is bound to (dr:blocks, decisions.md D83).
Shared :: struct {
	id: sim.Plugin_ID,
}

@(private)
shared_block: Shared
@(private)
shared := &shared_block

@(init, private)
declare_shared :: proc "contextless" () {
	blocks.declare({name = "plugins/extra_prefs", ptr = (^rawptr)(&shared), type = Shared})
}

id :: #force_inline proc "contextless" () -> sim.Plugin_ID {
	return shared.id
}
