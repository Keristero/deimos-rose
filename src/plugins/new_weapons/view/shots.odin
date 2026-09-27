package new_weapons_view

// New Weapons' screenshot scenarios (ui/shots.odin), for `mise run
// menu-shot MENU=<name>`. New content: visual checks.
//
// The loadout screen (plugins/loadout/view), played until the stage's
// title fades and the screen opens:
// - loadout: Level Select's stage 7, where the Chaingun unlocks (it is on
//   by default, so it is there unless the Mods page turned it off). Five
//   weapons for a loadout of three, so two wait in the new row; the cursor
//   is on the Chaingun.
// - loadout_2p: the same for two. Player 1 has picked up a new weapon and
//   moved onto the loadout; player 2 is on READY, which is refused.
// - loadout_placed: stage 2, with the Bacta Gun taken away first, so it
//   comes back as new, straight into the free slot.
//
// The Discharge Beam in play (docs/new-weapons.md) once stage 10's enemies
// are about. Player 1 is handed the weapon and the loadout screen is
// skipped. The Chaingun's are its own (plugins/chaingun/view).
// - discharge_windup: a press winding up, the motes drawn in to the gun;
// - discharge: a pulse as it fades;
// - discharge_charge: the charged beam the step after it is let go;
// - discharge_motes: its motes lingering along its path;
// - discharge_burst: the motes' fragments, just after they burst.


import "dr:plugins/loadout"
import "dr:plugins/new_weapons"
import "dr:sim"
import "dr:ui"

@(private = "file")
loadout_shot :: proc(s: ^sim.State, name: string) -> string {
	placed := name == "loadout_placed"
	if placed {
		loadout.slots_of(s, 0).loadout[1] = sim.NO_WEAPON
	}
	for i := 0; i < 2000 && !loadout.loadout_open(s); i += 1 {
		_ = sim.session_step(s, {})
	}
	if !loadout.loadout_open(s) {
		return "the screen never opened (is assets/extra there?)"
	}
	if !placed {
		loadout.loadout_of(s).boards[0].col = 1
	}
	if name == "loadout_2p" {
		b := &loadout.loadout_of(s).boards[0]
		b.holding, b.hold_row, b.hold_col = true, .Fresh, 0
		b.row, b.col = .Slots, 1
		loadout.loadout_of(s).boards[1].row = .Ready
	}
	return ""
}

// Player 1 flies the beam from the start of the stage, some steps in. An
// idle ship is shot down about 220 steps in.
@(private = "file")
discharge_shot :: proc(s: ^sim.State, name: string) -> string {
	loadout.loadout_of(s).shown = sim.single(s, sim.Level_Info).played
	if !loadout.loadout_give(s, 0, sim.res_id("aidb")) {
		return "no Discharge Beam (is assets/extra/new_weapons there?)"
	}
	for _ in 0 ..< (name == "discharge" || name == "discharge_windup" ? 180 : 120) {
		_ = sim.session_step(s, {})
	}
	return ""
}

// Fire held for some steps, then let go for some. A pulse fires 6 steps
// after its press (the wind-up); a full charge's motes burst 30 steps
// after the release.
@(private = "file", rodata)
DISCHARGE_WINDUP_PHASES := []ui.Shot_Phase{{1, {{.Fire_Air}, {}}}, {3, {}}}
@(private = "file", rodata)
DISCHARGE_PHASES := []ui.Shot_Phase{{1, {{.Fire_Air}, {}}}, {7, {}}}
@(private = "file", rodata)
DISCHARGE_CHARGE_PHASES := []ui.Shot_Phase{{90, {{.Fire_Air}, {}}}, {1, {}}}
@(private = "file", rodata)
DISCHARGE_MOTES_PHASES := []ui.Shot_Phase{{90, {{.Fire_Air}, {}}}, {16, {}}}
@(private = "file", rodata)
DISCHARGE_BURST_PHASES := []ui.Shot_Phase{{90, {{.Fire_Air}, {}}}, {32, {}}}

register_shots :: proc() {
	id := new_weapons.ID
	ui.shot_register({name = "loadout", plugin = id, level = 6, setup = loadout_shot})
	ui.shot_register({name = "loadout_2p", plugin = id, level = 6, co_op = true, setup = loadout_shot})
	ui.shot_register({name = "loadout_placed", plugin = id, level = 1, setup = loadout_shot})
	ui.shot_register({name = "discharge_windup", plugin = id, level = 9, setup = discharge_shot, phases = DISCHARGE_WINDUP_PHASES})
	ui.shot_register({name = "discharge", plugin = id, level = 9, setup = discharge_shot, phases = DISCHARGE_PHASES})
	ui.shot_register({name = "discharge_charge", plugin = id, level = 9, setup = discharge_shot, phases = DISCHARGE_CHARGE_PHASES})
	ui.shot_register({name = "discharge_motes", plugin = id, level = 9, setup = discharge_shot, phases = DISCHARGE_MOTES_PHASES})
	ui.shot_register({name = "discharge_burst", plugin = id, level = 9, setup = discharge_shot, phases = DISCHARGE_BURST_PHASES})
}

@(init)
register_shots_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/new_weapons/view register_shots", register_shots)
}
