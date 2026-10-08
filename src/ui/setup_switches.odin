package ui

// Plugins offered as a switch on the screens where a game is set up, as
// well as on the Mods page: Easy Mode on Level Select, Easy Mode and New
// Weapons in the netplay lobby. A plugin registers its own from its view/
// package, so the screens name none. Each switch reads "<LABEL>: ON" or
// "OFF", turns its plugin on with what comes with it, and is never shown
// in classic mode.

import "dr:render"
import "dr:sim"

MAX_SETUP_SWITCHES :: 4

// Between the centres of neighbouring switches: the lobby's pair sits 110
// either side of the middle, as it did before switches were registered.
SETUP_SWITCH_GAP :: 220

Setup_Screen :: enum {
	Level_Select,
	Lobby, // the netplay host's, before Ready
}

Setup_Switch :: struct {
	plugin:  sim.Plugin_ID,
	screens: bit_set[Setup_Screen],
}

@(private = "file")
setup_switches: sim.Registry(Setup_Switch, MAX_SETUP_SWITCHES)

// Called from registration steps only (sim.register_step). Switches sit
// left to right in registration order, which is the order of their views'
// step names.
setup_switch_register :: proc(s: Setup_Switch) {
	sim.registry_add(&setup_switches, s)
}

registered_setup_switches :: proc "contextless" () -> []Setup_Switch {
	return sim.registry_items(&setup_switches)
}

// The centre of switch `i` of `n` in a row, spread about the middle of
// the screen.
setup_switch_x :: proc(i, n: int) -> f32 {
	return render.SCREEN_W / 2 + (f32(i) - f32(n - 1) / 2) * SETUP_SWITCH_GAP
}
