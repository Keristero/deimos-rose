package game

import "dr:blocks"
import "dr:prefs"
import "dr:sim"

// What game keeps between calls, in a block a plugin's copy is bound to
// (dr:blocks, decisions.md D83): a plugin's screen imports game to work
// the menus and sessions it lends (screens.odin).
Shared :: struct {
	screens:   sim.Registry(Screen, MAX_SCREENS), // screens.odin
	campaigns: [sim.MAX_PLUGINS + 1]sim.Plugin_ID, // flow_campaigns' list
	mods_order: Mods_Order, // menu_mods.odin
	axis_was:  [sim.MAX_PLAYERS][prefs.Action][prefs.BINDING_SLOTS]bool, // binding_pressed's last frame
}

@(private)
shared_block: Shared
@(private)
shared := &shared_block

@(init, private)
declare_shared :: proc "contextless" () {
	blocks.declare({name = "game", ptr = (^rawptr)(&shared), type = Shared})
}
