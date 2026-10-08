package passives_view

import "dr:blocks"

// This package's state, in a block a plugin's copy of this package is bound
// to (dr:blocks, decisions.md D83).
Shared :: struct {
	// The clouds on screen, as the beams keep theirs (plugins/new_weapons/view).
	live: [dynamic]Cloud_Fx,
}

@(private)
shared_block: Shared
@(private)
shared := &shared_block

@(init, private)
declare_shared :: proc "contextless" () {
	blocks.declare({name = "plugins/passives/view", ptr = (^rawptr)(&shared), type = Shared})
}
