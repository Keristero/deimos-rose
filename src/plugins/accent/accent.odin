package accent

import "base:runtime"
// Imported for its registration: a dependency is always in the build.
import _ "dr:plugins/extra_prefs"
import "dr:sim"

// A colour of each player's choosing on their ship, its shots and an
// outline around it. Presentation only: it changes nothing in the
// simulation.

ID: sim.Plugin_ID

@(private = "file", rodata)
DEPS := []string{"extra_prefs"}

@(init)
register :: proc "contextless" () {
	context = runtime.default_context()
	ID = sim.plugin_register({
		name        = "accent",
		label       = "ACCENT COLOR",
		description = "Each player's own colour on their ship and shots",
		deps        = DEPS,
	})
}
