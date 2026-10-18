package chaingun_view

import "dr:blocks"
import "dr:sim"

// What this view keeps between frames, in a block a plugin's copy of this
// package is bound to (dr:blocks, decisions.md D83). flash.odin uses it.
Shared :: struct {
	flashes: [dynamic]Flash,
	sparks:  [dynamic]Spark,
	ships:   [sim.MAX_PLAYERS]Ship,
	seen:    i32, // the highest entity number looked at
}

@(private)
shared_block: Shared
@(private)
shared := &shared_block

@(init, private)
declare_shared :: proc "contextless" () {
	blocks.declare({name = "plugins/chaingun/view", ptr = (^rawptr)(&shared), type = Shared})
}
