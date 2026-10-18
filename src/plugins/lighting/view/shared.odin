package lighting_view

import "dr:blocks"
import "dr:prefs"

// This package's state, in a block a plugin's copy of this package is bound
// to (dr:blocks, decisions.md D83).
Shared :: struct {
	st:             State,
	light_strength: prefs.Setting_ID, // how brightly lights show on the ground and units
	glow_strength:  prefs.Setting_ID, // how strong the glow of what shines is
}

@(private)
shared_block: Shared
@(private)
shared := &shared_block

@(init, private)
declare_shared :: proc "contextless" () {
	blocks.declare({name = "plugins/lighting/view", ptr = (^rawptr)(&shared), type = Shared})
}

light_strength :: #force_inline proc "contextless" () -> prefs.Setting_ID {
	return shared.light_strength
}

glow_strength :: #force_inline proc "contextless" () -> prefs.Setting_ID {
	return shared.glow_strength
}
