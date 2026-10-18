package wind_view

import "dr:blocks"
import "dr:prefs"

// This package's state, in a block a plugin's copy of this package is bound
// to (dr:blocks, decisions.md D83).
Shared :: struct {
	strength: prefs.Setting_ID,
}

@(private)
shared_block: Shared
@(private)
shared := &shared_block

@(init, private)
declare_shared :: proc "contextless" () {
	blocks.declare({name = "plugins/wind/view", ptr = (^rawptr)(&shared), type = Shared})
}

strength :: #force_inline proc "contextless" () -> prefs.Setting_ID {
	return shared.strength
}
