package hitstop

// Imported for its registration: a dependency is always in the build.
import _ "dr:plugins/extra_prefs"
import "dr:sim"

// Hitstop: every collision holds the game still for a moment, the harder
// the hit the longer, and a blow that deals more than three times what its
// target had left stops the game for a kill cam: a zoom in on the unit
// with TAKEDOWN over it. Presentation only: it changes nothing in the
// simulation (the game is held between steps, not in them), it never holds
// a netplay match, and classic mode never sees it. See plugins/hitstop/view.

ID: sim.Plugin_ID

@(private = "file", rodata)
DEPS := []string{"extra_prefs"}

register :: proc() {
	ID = sim.plugin_register({
		name        = "hitstop",
		label       = "HITSTOP",
		description = "Hits stop the game for a moment; a huge one gets a kill cam",
		deps        = DEPS,
	})
}

@(init)
register_step :: proc "contextless" () {
	sim.register_step(.Plugin, "plugins/hitstop register", register)
}
