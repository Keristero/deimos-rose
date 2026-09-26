package new_weapons

import "base:runtime"
// Imported for their registration: a dependency is always in the build.
import _ "dr:plugins/extra_prefs"
import _ "dr:plugins/loadout"
import "dr:sim"

// The new weapons (assets/extra; docs/new-weapons.md): the original's
// rules never choose them (Weapon.extra), and this lets them in. They are
// handed over the way every other weapon is under plugins/loadout.

@(private = "file")
allows :: proc "contextless" (w: ^sim.Weapon) -> bool {
	return true
}

ID: sim.Plugin_ID

@(private = "file", rodata)
DEPS := []string{"extra_prefs", "loadout"}

@(init)
register :: proc "contextless" () {
	context = runtime.default_context()
	ID = sim.plugin_register({
		name        = "new_weapons",
		label       = "NEW WEAPONS",
		description = "New air weapons to unlock, stage by stage",
		deps        = DEPS,
		session     = true,
		default_on  = true,
	})
	sim.weapon_filter_register({plugin = ID, allows = allows})
}
