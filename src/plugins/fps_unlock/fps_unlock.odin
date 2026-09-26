package fps_unlock

import "base:runtime"
// Imported for its registration: a dependency is always in the build.
import _ "dr:plugins/extra_prefs"
import "dr:sim"

// Drawing faster than the original's 30 frames a second, blending between
// steps. Presentation only: the simulation steps as it always does.

ID: sim.Plugin_ID

@(private = "file", rodata)
DEPS := []string{"extra_prefs"}

@(init)
register :: proc "contextless" () {
	context = runtime.default_context()
	ID = sim.plugin_register({
		name        = "fps_unlock",
		label       = "30FPS UNLOCK",
		description = "Smoother motion at your display's refresh rate",
		deps        = DEPS,
	})
}
