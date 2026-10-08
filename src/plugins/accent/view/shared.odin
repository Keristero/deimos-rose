package accent_view

import "dr:blocks"
import "dr:prefs"

// This plugin's registration results, in a block a plugin's copy of this
// package is bound to (dr:blocks, decisions.md D83).
Shared :: struct {
	hue_p1:       prefs.Setting_ID, // player 1's colour, and yours in netplay: ship trim, crosshair and air-to-ground shots
	hue_p2:       prefs.Setting_ID, // player 2's colour in a local game
	self_outline: prefs.Setting_ID, // an outline in your accent round your own ship
}

@(private)
shared_block: Shared
@(private)
shared := &shared_block

@(init, private)
declare_shared :: proc "contextless" () {
	blocks.declare({name = "plugins/accent/view", ptr = (^rawptr)(&shared), type = Shared})
}

hue_p1 :: #force_inline proc "contextless" () -> prefs.Setting_ID {
	return shared.hue_p1
}

hue_p2 :: #force_inline proc "contextless" () -> prefs.Setting_ID {
	return shared.hue_p2
}

self_outline :: #force_inline proc "contextless" () -> prefs.Setting_ID {
	return shared.self_outline
}
