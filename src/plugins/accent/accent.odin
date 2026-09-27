package accent

// Imported for its registration: a dependency is always in the build.
import _ "dr:plugins/extra_prefs"
import "dr:sim"

// A colour of each player's choosing on their ship, its shots and an
// outline around it. Presentation only: it changes nothing in the
// simulation.

ID: sim.Plugin_ID

@(private = "file", rodata)
DEPS := []string{"extra_prefs"}

register :: proc() {
	ID = sim.plugin_register({
		name        = "accent",
		label       = "ACCENT COLOR",
		description = "Each player's own colour on their ship and shots",
		deps        = DEPS,
		default_on  = true,
	})
}

@(init)
register_step :: proc "contextless" () {
	sim.register_step(.Plugin, "plugins/accent register", register)
}
