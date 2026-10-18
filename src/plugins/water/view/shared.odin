package water_view

import "dr:blocks"
import "dr:prefs"

// This package's state, in a block a plugin's copy of this package is bound
// to (dr:blocks, decisions.md D83).
Shared :: struct {
	rip:      Ripples,
	strength: prefs.Setting_ID, // how strong the water's reflection and glint are
	st:       State,
}

@(private)
shared_block: Shared
@(private)
shared := &shared_block

@(init, private)
declare_shared :: proc "contextless" () {
	blocks.declare({name = "plugins/water/view", ptr = (^rawptr)(&shared), type = Shared})
}
