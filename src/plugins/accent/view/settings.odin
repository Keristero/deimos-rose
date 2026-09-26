package accent_view

import "base:runtime"
import "dr:plugins/accent"
import "dr:prefs"

// Accent Color's settings, on the Extra Preferences page. The keys are the
// ones these had before there were mods, so older saves keep their colours.

HUE_P1: prefs.Setting_ID // player 1's colour, and yours in netplay: ship trim, crosshair and air-to-ground shots
HUE_P2: prefs.Setting_ID // player 2's colour in a local game
SELF_OUTLINE: prefs.Setting_ID // an outline in your accent round your own ship

@(init)
register :: proc "contextless" () {
	context = runtime.default_context()
	// The cyan of the original crosshair.
	HUE_P1 = prefs.setting_register({plugin = accent.ID, key = "accent_hue", label = "P1 ACCENT HUE", kind = .Hue, default = 190})
	// Player 2's own gold (render/render.odin TRIM_SATURATION).
	HUE_P2 = prefs.setting_register({plugin = accent.ID, key = "accent_hue_p2", label = "P2 ACCENT HUE", kind = .Hue, default = 63})
	SELF_OUTLINE = prefs.setting_register({plugin = accent.ID, key = "self_outline", label = "SELF OUTLINE", kind = .Toggle})
}
