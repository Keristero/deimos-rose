package new_weapon_passives

// Imported for their registration: a dependency is always in the build.
import _ "dr:plugins/new_weapons"
import "dr:plugins/passives"
import "dr:sim"

// Passive upgrades for New Weapons' weapons: what Passive Upgrades
// (plugins/passives) and New Weapons add together. New content, not the
// original's. As a companion of both (D66) it is on wherever they are, and
// a player can keep the weapons and turn their upgrades off. Each passive
// is offered only while its weapon can be flown (passives.passive_available),
// so the Chaingun's needs the Chaingun's plugin on as well.
// docs/passive-upgrades.md records how each was read.

ID: sim.Plugin_ID

// The design's Weapon 5 and 6: the Chaingun (plugins/chaingun) and the
// Discharge Beam (plugins/new_weapons).
WEAPON_5: passives.Passive
WEAPON_6: passives.Passive

WEAPON_CHAINGUN :: sim.Res_ID{'a', 'i', 'c', 'g'}
WEAPON_DISCHARGE_BEAM :: sim.Res_ID{'a', 'i', 'd', 'b'}

// Tuned by the DPS report, as Passive Upgrades' own weapon passives are
// (plugins/passives).
@(private = "file", rodata)
CHAINGUN_MODS := []passives.Mod {
	// A burst of 10 rounds takes 20 steps, and the gap after it is the
	// firing delay's 30 less those; these close 40%, 60% and all of it
	// (26, 24, 20), so level 3 fires without a break. The rounds' spread
	// widens with it.
	{.Firing_Delay, .Decrease, {13, 20, 33}},
	{.Random_Spread_Range, .Increase, {25, 50, 100}},
}

@(private = "file", rodata)
DISCHARGE_BEAM_MODS := []passives.Mod {
	// The damage bases the charge too (+13/26/53% on it); the beam's width
	// takes the damage's percentage as well as its own. The design's
	// 10/20/30% damage gains only 7/14/21%: in the wave a pulse already
	// kills what it hits, so only the single and cluster targets gain.
	{.Projectile_Damage, .Increase, {15, 30, 60}},
	{.Shot_Width, .Increase, {10, 20, 30}},
}

@(private = "file", rodata)
DEPS := []string{"passives", "new_weapons"}

register :: proc() {
	ID = sim.plugin_register({
		name        = "new_weapon_passives",
		label       = "NEW WEAPON UPGRADES",
		description = "Passive upgrades for the new weapons",
		deps        = DEPS,
		session     = true,
		companion   = true,
	})
	// Their names are the ones the passives had when Passive Upgrades
	// carried them: the icons and the golden runs find them by name.
	WEAPON_5 = passives.passive_register({name = "weapon_5", label = "CHAINGUN UPGRADE", plugin = ID, levels = 3, weapon = WEAPON_CHAINGUN, mods = CHAINGUN_MODS})
	WEAPON_6 = passives.passive_register({name = "weapon_6", label = "DISCHARGE BEAM UPGRADE", plugin = ID, levels = 3, weapon = WEAPON_DISCHARGE_BEAM, mods = DISCHARGE_BEAM_MODS})
}

@(init)
register_step :: proc "contextless" () {
	sim.register_step(.Plugin, "plugins/new_weapon_passives register", register)
}
