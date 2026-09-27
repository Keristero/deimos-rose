package extra_prefs

import "dr:sim"

// A page of preferences the original does not have, where the other plugins
// put their settings. It changes nothing in the simulation.

ID: sim.Plugin_ID

register :: proc() {
	ID = sim.plugin_register({
		name        = "extra_prefs",
		label       = "EXTRA PREFERENCES",
		description = "A page of settings for the other mods",
	})
}

@(init)
register_step :: proc "contextless" () {
	sim.register_step(.Plugin, "plugins/extra_prefs register", register)
}
