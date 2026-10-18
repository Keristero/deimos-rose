package new_weapon_passives_view

// New Weapon Passives' screenshot scenario (ui/shots.odin), for `mise run
// menu-shot MENU=chaingun_upgrade` and the site's picture of the plugin:
// on stage 7 once its enemies are about, player 1 handed the Chaingun with
// its upgrade (Weapon 5) at level 3, fire tapped, so the bursts run on without
// a break and spread wide. New content: a visual check.

import "dr:plugins/loadout"
import "dr:plugins/new_weapon_passives"
import "dr:plugins/passives"
import "dr:sim"
import "dr:ui"

@(private = "file")
chaingun_upgrade_shot :: proc(s: ^sim.State, name: string) -> string {
	loadout.loadout_of(s).shown = sim.single(s, sim.Level_Info).played
	if !loadout.loadout_give(s, 0, new_weapon_passives.WEAPON_CHAINGUN) {
		return "no Chaingun (is plugins/chaingun/data there?)"
	}
	passives.levels_of(s, 0)[new_weapon_passives.weapon_5()] = 3
	// An idle ship is shot down about 220 steps in (chaingun/view/shots.odin).
	for _ in 0 ..< 120 {
		_ = sim.session_step(s, {})
	}
	return ""
}

// Fire tapped (held, it would charge) for several bursts, with no gap
// between them at level 3.
@(private = "file", rodata)
TAPPED := []ui.Shot_Phase {
	{3, {{.Fire_Air}, {}}}, {3, {}},
	{3, {{.Fire_Air}, {}}}, {3, {}},
	{3, {{.Fire_Air}, {}}}, {3, {}},
	{3, {{.Fire_Air}, {}}}, {3, {}},
	{3, {{.Fire_Air}, {}}}, {3, {}},
	{3, {{.Fire_Air}, {}}}, {3, {}},
}

register_shots :: proc() {
	ui.shot_register({name = "chaingun_upgrade", plugin = new_weapon_passives.id(), level = 6, setup = chaingun_upgrade_shot, phases = TAPPED})
}

@(init)
register_shots_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/new_weapon_passives/view register_shots", register_shots)
}
