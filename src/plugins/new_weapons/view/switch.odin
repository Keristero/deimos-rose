package new_weapons_view

import "dr:plugins/new_weapons"
import "dr:sim"
import "dr:ui"

// New Weapons' switch in the netplay lobby: one for the whole group, so
// turning it on brings the Chaingun back with it.

register_switch :: proc() {
	ui.setup_switch_register({plugin = new_weapons.id(), screens = {.Lobby}})
}

@(init)
register_switch_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/new_weapons/view register_switch", register_switch)
}
