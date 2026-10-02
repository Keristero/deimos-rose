package chaingun

// Imported for its registration: a dependency is always in the build.
import _ "dr:plugins/new_weapons"
import "dr:sim"

// The Chaingun (docs/new-weapons.md): a new air weapon from stage 7 whose
// charge fires volleys aimed at the nearest enemy (aimed.odin). New
// content, not the original's. Everything that is the Chaingun's is here:
// its content in data/ and sprites/ here (records by hand, sprites from
// tools/recolour/chaingun.json), the definition key that marks its charge,
// the firing hook that reads it, and its screenshot scenarios (view/).
//
// It needs New Weapons, which hands the new weapons over through the
// loadout and gives the aim its targets (collision_system.air_shot_can_hit).

ID: sim.Plugin_ID

// The charge fires aimed volleys at the nearest enemy (sim/def_keys.odin).
AIMED_RELEASE: sim.Weapon_Key

@(private = "file")
is_aimed :: proc "contextless" (w: ^sim.Weapon) -> bool {
	return sim.weapon_bool(w, AIMED_RELEASE)
}

@(private = "file", rodata)
DEPS := []string{"new_weapons"}

register :: proc() {
	ID = sim.plugin_register({
		name        = "chaingun",
		label       = "CHAINGUN",
		description = "An air weapon from stage 7 whose charge fires aimed volleys",
		deps        = DEPS,
		session     = true,
		default_on  = true,
		content     = true,
	})
	AIMED_RELEASE = sim.weapon_key_register("x_AimedRelease_BOOL")
	sim.weapon_fire_register({plugin = ID, fires = is_aimed, volley = aimed_release_spawn})
}

@(init)
register_step :: proc "contextless" () {
	sim.register_step(.Plugin, "plugins/chaingun register", register)
}
