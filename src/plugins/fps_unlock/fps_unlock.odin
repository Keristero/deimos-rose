package fps_unlock

// Imported for its registration: a dependency is always in the build.
import _ "dr:plugins/extra_prefs"
import "dr:sim"

// Drawing faster than the original's 30 frames a second, blending between
// steps. Presentation only: the simulation steps as it always does.

ID: sim.Plugin_ID

@(private = "file", rodata)
DEPS := []string{"extra_prefs"}

register :: proc() {
	ID = sim.plugin_register({
		name        = "fps_unlock",
		label       = "30FPS UNLOCK",
		description = "Smoother motion at your display's refresh rate",
		deps        = DEPS,
	})
}

@(init)
register_step :: proc "contextless" () {
	sim.register_step(.Plugin, "plugins/fps_unlock register", register)
}
