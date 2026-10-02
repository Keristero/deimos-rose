package water

// Imported for its registration: a dependency is always in the build.
import _ "dr:plugins/extra_prefs"
import "dr:sim"

// Moving water: the level's water, as its media mask marks it, gets waves
// the wind drives, a reflection of a sky with clouds and a glint of the sun.
// Presentation only: it changes nothing in the simulation, and classic
// mode never sees it. Drawn by plugins/water/view.

ID: sim.Plugin_ID

@(private = "file", rodata)
DEPS := []string{"extra_prefs"}

register :: proc() {
	ID = sim.plugin_register({
		name        = "water",
		label       = "MOVING WATER",
		description = "Waves, a sky and its clouds, and the sun's glint on the water",
		deps        = DEPS,
	})
}

@(init)
register_step :: proc "contextless" () {
	sim.register_step(.Plugin, "plugins/water register", register)
}
