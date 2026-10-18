package prefs

import "dr:blocks"
import "dr:sim"

// What prefs registers, in a block a plugin's copy is bound to (dr:blocks,
// decisions.md D83).
Shared :: struct {
	// settings.odin
	settings:        [MAX_SETTINGS]Setting,
	setting_count:   int,
	settings_page:   sim.Plugin_ID,
	// launch.odin
	launch_switches: sim.Registry(Launch_Switch, MAX_LAUNCH_SWITCHES),
}

@(private)
shared_block: Shared
@(private)
shared := &shared_block

@(init, private)
declare_shared :: proc "contextless" () {
	blocks.declare({name = "prefs", ptr = (^rawptr)(&shared), type = Shared})
}
