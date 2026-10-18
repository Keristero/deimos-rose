package data

import "dr:blocks"

// What data keeps between calls, in a block a plugin's copy is bound to
// (dr:blocks, decisions.md D83). plugins.odin uses both.
Shared :: struct {
	extra_roots: [dynamic]string, // plugins roots from -plugins, before $DR_PLUGINS
	discovered:  map[string]string, // each discovered plugin's folder, by name
}

@(private)
shared_block: Shared
@(private)
shared := &shared_block

@(init, private)
declare_shared :: proc "contextless" () {
	blocks.declare({name = "data", ptr = (^rawptr)(&shared), type = Shared})
}
