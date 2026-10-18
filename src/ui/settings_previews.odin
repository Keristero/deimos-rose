package ui

// Previews on the Extras page: what a plugin's settings do, drawn beside
// its rows (Accent Color's two ships). A plugin registers its own from its
// view/ package, and it is drawn while the plugin is among the saved mods,
// as its rows are.

import "dr:prefs"
import "dr:render"
import "dr:sim"

MAX_SETTINGS_PREVIEWS :: 4

Settings_Preview :: struct {
	plugin: sim.Plugin_ID,
	// `values` are the saved settings, by prefs.Setting_ID; `live` is
	// whether the plugin is in effect (it is not in classic mode), so the
	// preview can show what play would.
	draw:   proc(r: ^render.Renderer, values: ^[prefs.MAX_SETTINGS]int, live: bool),
}

// Called from registration steps only (sim.register_step).
settings_preview_register :: proc(p: Settings_Preview) {
	sim.registry_add(&shared.previews, p)
}

registered_settings_previews :: proc "contextless" () -> []Settings_Preview {
	return sim.registry_items(&shared.previews)
}
