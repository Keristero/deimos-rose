package lighting

// Imported for its registration: a dependency is always in the build.
import _ "dr:plugins/extra_prefs"
import "dr:sim"

// Realtime lights and a glow: what shines (the player's shots, muzzle
// flashes, bright sparks) lights the ground and the units round it, and
// blooms. Presentation only: it changes nothing in the simulation, and
// classic mode never sees it. Drawn by plugins/lighting/view as a post pass
// (render/post.odin).

ID: sim.Plugin_ID

@(private = "file", rodata)
DEPS := []string{"extra_prefs"}

register :: proc() {
	ID = sim.plugin_register({
		name        = "lighting",
		label       = "REALTIME LIGHTING",
		description = "Shots and explosions light what is round them, and glow",
		deps        = DEPS,
	})
}

@(init)
register_step :: proc "contextless" () {
	sim.register_step(.Plugin, "plugins/lighting register", register)
}
