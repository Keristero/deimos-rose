package new_weapons

import "base:runtime"
// Imported for their registration: a dependency is always in the build.
import _ "dr:plugins/extra_prefs"
import _ "dr:plugins/loadout"
import "dr:sim"

// The new weapons (assets/extra; docs/new-weapons.md): the original's
// rules never choose them (Weapon.extra), and this lets them in. They are
// handed over the way every other weapon is under plugins/loadout.
//
// What they do that no original weapon does is here too: the Discharge
// Beam's instant shot (beam.odin) and the Chaingun's aimed release
// (aimed.odin), each fired through the core's Weapon_Fire hook for the
// weapons whose definitions carry this plugin's keys, and drawn by its view.

@(private = "file")
allows :: proc "contextless" (w: ^sim.Weapon) -> bool {
	return true
}

ID: sim.Plugin_ID

// Keys on the new weapons' definitions (sim/def_keys.odin).
AIMED_RELEASE: sim.Weapon_Key // the charge fires aimed volleys at the nearest enemy
BEAM: sim.Weapon_Key // an instant laser instead of projectiles
BEAM_DAMAGE, BEAM_WIDTH, BEAM_RELEASE_DAMAGE, BEAM_RELEASE_WIDTH: sim.Weapon_Key
BEAM_SHRAPNEL, BEAM_SHRAPNEL_COUNT: sim.Weapon_Key

// The beam's shots, for the view (sim/queue_effects.odin).
BEAM_SHOT: sim.Effect_Kind

@(private = "file")
is_beam :: proc "contextless" (w: ^sim.Weapon) -> bool {
	return sim.weapon_bool(w, BEAM)
}

@(private = "file")
is_aimed :: proc "contextless" (w: ^sim.Weapon) -> bool {
	return sim.weapon_bool(w, AIMED_RELEASE)
}

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

	AIMED_RELEASE = sim.weapon_key_register("x_AimedRelease_BOOL")
	BEAM = sim.weapon_key_register("x_Beam_BOOL")
	BEAM_DAMAGE = sim.weapon_key_register("x_BeamDamage_FLOAT")
	BEAM_WIDTH = sim.weapon_key_register("x_BeamWidth_FLOAT")
	BEAM_RELEASE_DAMAGE = sim.weapon_key_register("x_BeamReleaseDamage_FLOAT")
	BEAM_RELEASE_WIDTH = sim.weapon_key_register("x_BeamReleaseWidth_FLOAT")
	BEAM_SHRAPNEL = sim.weapon_key_register("x_BeamShrapnel_ID")
	BEAM_SHRAPNEL_COUNT = sim.weapon_key_register("x_BeamShrapnelCount_INT")
	BEAM_SHOT = sim.effect_kind_register(Beam_Event)

	sim.weapon_fire_register({plugin = ID, fires = is_beam, shot = beam_shot, release = beam_release})
	sim.weapon_fire_register({plugin = ID, fires = is_aimed, volley = aimed_release_spawn})
}
