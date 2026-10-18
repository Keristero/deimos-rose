package prefs

import "dr:sim"

// Command-line switches that turn a plugin on for one run without saving
// it (-highrefreshrate is 30FPS Unlock's). A plugin's view registers its
// own, so the game parses no flag that belongs to a plugin: it keeps the
// arguments, and reads them here once registration is done. `-mod <name>`
// does the same for any plugin, by its name (a test turns Easy Mode on
// so).

MAX_LAUNCH_SWITCHES :: 8

Launch_Switch :: struct {
	flag:   string, // as typed, "-highrefreshrate"
	plugin: sim.Plugin_ID,
}

// Called from registration steps only (sim.register_step), like setting_register.
launch_switch_register :: proc(s: Launch_Switch) {
	sim.registry_add(&shared.launch_switches, s)
}

// The plugins a run's arguments switch on.
launch_mods :: proc(args: []string) -> (mods: sim.Mods) {
	for a, i in args {
		for s in sim.registry_items(&shared.launch_switches) {
			if a == s.flag {
				mods += {int(s.plugin)}
			}
		}
		if a == "-mod" && i + 1 < len(args) {
			if id, ok := sim.plugin_find(args[i + 1]); ok {
				mods += {int(id)}
			}
		}
	}
	return
}
