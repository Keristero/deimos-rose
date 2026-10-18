package new_weapons

// Imported for their registration: a dependency is always in the build.
import _ "dr:plugins/extra_prefs"
import _ "dr:plugins/loadout"
import "dr:sim"

// The new weapons (their content in data/ and sprites/ here;
// docs/new-weapons.md): the original's rules never choose them
// (Weapon.extra), and they are in play while this is on. They are handed
// over the way every other weapon is under plugins/loadout.
//
// What they do that no original weapon does is here too: the Discharge
// Beam's instant shot (beam.odin), fired through the core's Weapon_Fire
// hook for the weapons whose definitions carry this plugin's keys, and
// drawn by its view. A weapon can also be a plugin of its own that needs
// this one, as the Chaingun is (plugins/chaingun): it lists under New
// Weapons on the Mods page, and goes when New Weapons does.

@(private = "file")
is_beam :: proc "contextless" (w: ^sim.Weapon) -> bool {
	return sim.weapon_bool(w, shared.beam)
}

@(private = "file", rodata)
DEPS := []string{"extra_prefs", "loadout"}

register :: proc() {
	shared.id = sim.plugin_register({
		name        = "new_weapons",
		label       = "NEW WEAPONS",
		description = "New air weapons to unlock, stage by stage",
		deps        = DEPS,
		session     = true,
		default_on  = true,
		content     = true,
	})

	shared.beam = sim.weapon_key_register("x_Beam_BOOL")
	shared.beam_damage = sim.weapon_key_register("x_BeamDamage_FLOAT")
	shared.beam_width = sim.weapon_key_register("x_BeamWidth_FLOAT")
	shared.beam_release_damage = sim.weapon_key_register("x_BeamReleaseDamage_FLOAT")
	shared.beam_release_width = sim.weapon_key_register("x_BeamReleaseWidth_FLOAT")
	shared.beam_windup = sim.weapon_key_register("x_BeamWindup_INT")
	shared.beam_flash = sim.weapon_key_register("x_BeamFlash_ID")
	shared.beam_shot = sim.effect_kind_register(Beam_Event)
	sim.kind_component(.Session, Beam_Log{}, shared.id)

	sim.weapon_fire_register({plugin = shared.id, fires = is_beam, shot = beam_shot, release = beam_release, windup = beam_windup})
}

@(init)
register_step :: proc "contextless" () {
	sim.register_step(.Plugin, "plugins/new_weapons register", register)
}
