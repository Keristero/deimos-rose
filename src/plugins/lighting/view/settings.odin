package lighting_view

import "dr:plugins/lighting"
import "dr:prefs"
import "dr:sim"

// Realtime Lighting's settings, on the Extra Preferences page. At 0 a pass
// is off and costs nothing.

LIGHT_STRENGTH: prefs.Setting_ID // how brightly lights show on the ground and units
GLOW_STRENGTH: prefs.Setting_ID // how strong the glow of what shines is

register :: proc() {
	LIGHT_STRENGTH = prefs.setting_register({plugin = lighting.ID, key = "light_strength", label = "LIGHT STRENGTH", kind = .Percent, default = 60})
	GLOW_STRENGTH = prefs.setting_register({plugin = lighting.ID, key = "glow_strength", label = "GLOW STRENGTH", kind = .Percent, default = 35})
}

@(init)
register_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/lighting/view register", register)
}
