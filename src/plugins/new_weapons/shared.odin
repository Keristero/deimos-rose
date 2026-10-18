package new_weapons

import "dr:blocks"
import "dr:sim"

// This plugin's registration results, in a block a plugin's copy of this
// package is bound to (dr:blocks, decisions.md D83).
Shared :: struct {
	id:                  sim.Plugin_ID,
	// Keys on the new weapons' definitions (sim/def_keys.odin).
	beam:                sim.Weapon_Key, // an instant laser instead of projectiles
	beam_damage:         sim.Weapon_Key,
	beam_width:          sim.Weapon_Key,
	beam_release_damage: sim.Weapon_Key,
	beam_release_width:  sim.Weapon_Key,
	beam_windup:         sim.Weapon_Key,
	beam_flash:          sim.Weapon_Key,
	beam_shot:           sim.Effect_Kind, // the beam's shots, for the view (sim/queue_effects.odin)
}

@(private)
shared_block: Shared
@(private)
shared := &shared_block

@(init, private)
declare_shared :: proc "contextless" () {
	blocks.declare({name = "plugins/new_weapons", ptr = (^rawptr)(&shared), type = Shared})
}

id :: #force_inline proc "contextless" () -> sim.Plugin_ID {
	return shared.id
}

beam :: #force_inline proc "contextless" () -> sim.Weapon_Key {
	return shared.beam
}

beam_damage :: #force_inline proc "contextless" () -> sim.Weapon_Key {
	return shared.beam_damage
}

beam_flash :: #force_inline proc "contextless" () -> sim.Weapon_Key {
	return shared.beam_flash
}
