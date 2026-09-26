package extra_prefs

import "base:runtime"
import "dr:sim"

// A page of preferences the original does not have, where the other plugins
// put their settings. It changes nothing in the simulation.

ID: sim.Plugin_ID

@(init)
register :: proc "contextless" () {
	context = runtime.default_context()
	ID = sim.plugin_register({
		name        = "extra_prefs",
		label       = "EXTRA PREFERENCES",
		description = "A page of settings for the other mods",
	})
}
