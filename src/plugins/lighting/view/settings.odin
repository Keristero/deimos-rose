package lighting_view

import "dr:plugins/lighting"
import "dr:prefs"
import "dr:sim"

// Realtime Lighting's settings, on the Extra Preferences page. At 0 a pass
// is off and costs nothing.

register :: proc() {
	shared.light_strength = prefs.setting_register({plugin = lighting.id(), key = "light_strength", label = "LIGHT STRENGTH", kind = .Percent, default = 60})
	shared.glow_strength = prefs.setting_register({plugin = lighting.id(), key = "glow_strength", label = "GLOW STRENGTH", kind = .Percent, default = 12})
}

@(init)
register_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/lighting/view register", register)
}
