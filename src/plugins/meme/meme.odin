package meme

// Imported for its registration: a dependency is always in the build.
import _ "dr:plugins/extra_prefs"
import "dr:sim"

// The Meme Mod. Hitstop: every collision holds the game still for a moment, the harder
// the hit the longer, and a blow that deals more than three times what its
// target had left stops the game for a kill cam: a zoom in on the unit
// with TAKEDOWN over it. Presentation only: it changes nothing in the
// simulation (the game is held between steps, not in them), it never holds
// a netplay match, and classic mode never sees it. See plugins/meme/view;
// the kill streak's announcer, the combo meter and the horn are there too.

@(private = "file", rodata)
DEPS := []string{"extra_prefs"}

register :: proc() {
	shared.id = sim.plugin_register({
		name        = "meme",
		label       = "MEME MOD",
		description = "Hits stop the game, a huge one gets a kill cam, and an announcer calls the streak",
		deps        = DEPS,
	})
}

@(init)
register_step :: proc "contextless" () {
	sim.register_step(.Plugin, "plugins/meme register", register)
}
