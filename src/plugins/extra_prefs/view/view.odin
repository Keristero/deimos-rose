package extra_prefs_view

import "dr:plugins/extra_prefs"
import "dr:prefs"
import "dr:sim"

// Extra Preferences is the Extras page: the game draws every plugin's
// settings there, and opens it while this plugin is on.

register :: proc() {
	prefs.settings_page_register(extra_prefs.ID)
}

@(init)
register_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/extra_prefs/view register", register)
}
