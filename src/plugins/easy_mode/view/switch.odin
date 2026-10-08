package easy_mode_view

import "dr:plugins/easy_mode"
import "dr:sim"
import "dr:ui"

// Easy Mode's switch, on Level Select and in the netplay lobby, and the
// screenshot of Level Select with it on.

register_switch :: proc() {
	ui.setup_switch_register({plugin = easy_mode.id(), screens = {.Level_Select, .Lobby}})
	ui.menu_shot_register({name = "level_select_easy", plugin = easy_mode.id(), screen = "level_select", })
}

@(init)
register_switch_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/easy_mode/view register_switch", register_switch)
}
