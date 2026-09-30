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

ID: sim.Plugin_ID

// Keys on the new weapons' definitions (sim/def_keys.odin).
BEAM: sim.Weapon_Key // an instant laser instead of projectiles
BEAM_DAMAGE, BEAM_WIDTH, BEAM_RELEASE_DAMAGE, BEAM_RELEASE_WIDTH: sim.Weapon_Key
BEAM_WINDUP, BEAM_FLASH: sim.Weapon_Key
BEAM_MOTE, BEAM_MOTE_SOUNDED, BEAM_MOTE_SPACING, BEAM_MOTE_DELAY_MIN, BEAM_MOTE_DELAY_MAX: sim.Weapon_Key

// The beam's shots, for the view (sim/queue_effects.odin).
BEAM_SHOT: sim.Effect_Kind

@(private = "file")
is_beam :: proc "contextless" (w: ^sim.Weapon) -> bool {
	return sim.weapon_bool(w, BEAM)
}

@(private = "file", rodata)
DEPS := []string{"extra_prefs", "loadout"}

register :: proc() {
	ID = sim.plugin_register({
		name        = "new_weapons",
		label       = "NEW WEAPONS",
		description = "New air weapons to unlock, stage by stage",
		deps        = DEPS,
		session     = true,
		default_on  = true,
		content     = true,
	})

	BEAM = sim.weapon_key_register("x_Beam_BOOL")
	BEAM_DAMAGE = sim.weapon_key_register("x_BeamDamage_FLOAT")
	BEAM_WIDTH = sim.weapon_key_register("x_BeamWidth_FLOAT")
	BEAM_RELEASE_DAMAGE = sim.weapon_key_register("x_BeamReleaseDamage_FLOAT")
	BEAM_RELEASE_WIDTH = sim.weapon_key_register("x_BeamReleaseWidth_FLOAT")
	BEAM_WINDUP = sim.weapon_key_register("x_BeamWindup_INT")
	BEAM_FLASH = sim.weapon_key_register("x_BeamFlash_ID")
	BEAM_MOTE = sim.weapon_key_register("x_BeamMote_ID")
	BEAM_MOTE_SOUNDED = sim.weapon_key_register("x_BeamMoteSounded_ID")
	BEAM_MOTE_SPACING = sim.weapon_key_register("x_BeamMoteSpacing_INT")
	BEAM_MOTE_DELAY_MIN = sim.weapon_key_register("x_BeamMoteDelayMin_INT")
	BEAM_MOTE_DELAY_MAX = sim.weapon_key_register("x_BeamMoteDelayMax_INT")
	BEAM_SHOT = sim.effect_kind_register(Beam_Event)
	sim.kind_component(.Session, Beam_Log{}, ID)

	sim.weapon_fire_register({plugin = ID, fires = is_beam, shot = beam_shot, release = beam_release, windup = beam_windup})
}

@(init)
register_step :: proc "contextless" () {
	sim.register_step(.Plugin, "plugins/new_weapons register", register)
}
