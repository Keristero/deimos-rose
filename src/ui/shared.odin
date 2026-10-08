package ui

import "dr:blocks"
import "dr:sim"

// What ui registers, in a block a plugin's copy is bound to (dr:blocks,
// decisions.md D83).
Shared :: struct {
	overlays:       sim.Registry(Overlay, MAX_OVERLAYS), // overlays.odin
	previews:       sim.Registry(Settings_Preview, MAX_SETTINGS_PREVIEWS), // settings_previews.odin
	setup_switches: sim.Registry(Setup_Switch, MAX_SETUP_SWITCHES), // setup_switches.odin
	shots:          sim.Registry(Shot, MAX_SHOTS), // shots.odin
	menu_shots:     sim.Registry(Menu_Shot, MAX_MENU_SHOTS),
}

@(private)
shared_block: Shared
@(private)
shared := &shared_block

@(init, private)
declare_shared :: proc "contextless" () {
	blocks.declare({name = "ui", ptr = (^rawptr)(&shared), type = Shared})
}
