package accent_view

import "dr:plugins/accent"
import "dr:prefs"
import "dr:sim"

// Accent Color's settings, on the Extra Preferences page. The keys are the
// ones these had before there were mods, so older saves keep their colours.

register :: proc() {
	// The cyan of the original crosshair.
	shared.hue_p1 = prefs.setting_register({plugin = accent.id(), key = "accent_hue", label = "P1 ACCENT HUE", kind = .Hue, default = 190, player = 1})
	// Player 2's own gold (render/render.odin TRIM_SATURATION).
	shared.hue_p2 = prefs.setting_register({plugin = accent.id(), key = "accent_hue_p2", label = "P2 ACCENT HUE", kind = .Hue, default = 63, player = 2})
	shared.self_outline = prefs.setting_register({plugin = accent.id(), key = "self_outline", label = "SELF OUTLINE", kind = .Toggle})
}

@(init)
register_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/accent/view register", register)
}
