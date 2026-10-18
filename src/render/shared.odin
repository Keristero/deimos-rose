package render

import "dr:blocks"
import "dr:sim"

// What render registers, in a block a plugin's copy is bound to
// (dr:blocks, decisions.md D83).
Shared :: struct {
	render_systems: sim.Registry(Render_System, MAX_RENDER_SYSTEMS), // render_systems.odin
	effect_systems: sim.Registry(Effect_System, MAX_EFFECT_SYSTEMS),
	frame_rates:    sim.Registry(Frame_Rate, MAX_FRAME_RATES), // frame_rate.odin
	post_passes: sim.Registry(Post_Pass, MAX_POST_PASSES),
}

@(private)
shared_block: Shared
@(private)
shared := &shared_block

@(init, private)
declare_shared :: proc "contextless" () {
	blocks.declare({name = "render", ptr = (^rawptr)(&shared), type = Shared})
}
