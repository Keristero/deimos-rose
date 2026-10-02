package wind

// Imported for its registration: a dependency is always in the build.
import _ "dr:plugins/extra_prefs"
import "dr:sim"

// The level's wind blows the visual particles (sparks, smoke, debris).
// Presentation only: it changes nothing in the simulation, and classic
// mode never sees it. Moved by plugins/wind/view.

ID: sim.Plugin_ID

@(private = "file", rodata)
DEPS := []string{"extra_prefs"}

register :: proc() {
	ID = sim.plugin_register({
		name        = "wind",
		label       = "WIND",
		description = "The level's wind blows sparks and smoke",
		deps        = DEPS,
	})
}

@(init)
register_step :: proc "contextless" () {
	sim.register_step(.Plugin, "plugins/wind register", register)
}
