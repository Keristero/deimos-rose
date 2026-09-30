package chaingun_view

// The Chaingun's screenshot scenarios (ui/shots.odin), for `mise run
// menu-shot MENU=<name>`: on stage 7 once its enemies are about, player 1
// handed the weapon and the loadout screen skipped. New content: visual
// checks.
// - chaingun: the burst a moment after a press;
// - chaingun_charge: the aimed volleys a moment after a charge is let go;
// - chaingun_release: the step a charge is let go, its muzzle flash at full
//   strength (chaingun: the burst's, at half).


import "dr:plugins/chaingun"
import "dr:plugins/loadout"
import "dr:sim"
import "dr:ui"

@(private = "file")
chaingun_shot :: proc(s: ^sim.State, name: string) -> string {
	loadout.loadout_of(s).shown = sim.single(s, sim.Level_Info).played
	if !loadout.loadout_give(s, 0, sim.res_id("aicg")) {
		return "no Chaingun (is plugins/chaingun/data there?)"
	}
	// An idle ship is shot down about 220 steps in.
	for _ in 0 ..< (name == "chaingun" ? 180 : 120) {
		_ = sim.session_step(s, {})
	}
	return ""
}

// Fire held for some steps, then let go for some.
@(private = "file", rodata)
TAP := []ui.Shot_Phase{{4, {{.Fire_Air}, {}}}, {6, {}}}
@(private = "file", rodata)
CHARGE := []ui.Shot_Phase{{70, {{.Fire_Air}, {}}}, {12, {}}}
@(private = "file", rodata)
RELEASE := []ui.Shot_Phase{{70, {{.Fire_Air}, {}}}, {1, {}}}

register_shots :: proc() {
	ui.shot_register({name = "chaingun", plugin = chaingun.ID, level = 6, setup = chaingun_shot, phases = TAP})
	ui.shot_register({name = "chaingun_charge", plugin = chaingun.ID, level = 6, setup = chaingun_shot, phases = CHARGE})
	ui.shot_register({name = "chaingun_release", plugin = chaingun.ID, level = 6, setup = chaingun_shot, phases = RELEASE})
}

@(init)
register_shots_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/chaingun/view register_shots", register_shots)
}
