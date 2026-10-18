package new_weapons_view

import "dr:blocks"
import "dr:sim"

// What this view keeps between frames, in a block a plugin's copy of this
// package is bound to (dr:blocks, decisions.md D83).
Shared :: struct {
	// The beams on screen (beams.odin). Presentation keeps one set, as the
	// game has one screen; cleared with the rest of the in-play effects.
	live:  [dynamic]Beam_Fx,
	motes: [dynamic]Precharge_Mote, // precharge.odin
	guns:  [sim.MAX_PLAYERS]Gun,
}

@(private)
shared_block: Shared
@(private)
shared := &shared_block

@(init, private)
declare_shared :: proc "contextless" () {
	blocks.declare({name = "plugins/new_weapons/view", ptr = (^rawptr)(&shared), type = Shared})
}
