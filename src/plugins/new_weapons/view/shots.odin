package new_weapons_view

// New Weapons' screenshot scenarios (ui/shots.odin), for `mise run
// menu-shot MENU=<name>`. New content: visual checks.
//
// The loadout screen (plugins/loadout/view), played until the stage's
// title fades and the screen opens:
// - loadout: Level Select's stage 7, where the Chaingun unlocks. Five
//   weapons for a loadout of three, so two wait in the new row; the cursor
//   is on the Chaingun.
// - loadout_2p: the same for two. Player 1 has picked up a new weapon and
//   moved onto the loadout; player 2 is on READY, which is refused.
// - loadout_placed: stage 2, with the Bacta Gun taken away first, so it
//   comes back as new, straight into the free slot.
//
// A new weapon in play (docs/new-weapons.md) once its stage's enemies are
// about: the Chaingun on stage 7, the Discharge Beam on stage 10. Player 1
// is handed the weapon and the loadout screen is skipped.
// - chaingun: the burst a moment after a press;
// - chaingun_charge: the aimed volleys a moment after a charge is let go;
// - discharge: a pulse as it fades;
// - discharge_charge: the charged beam the step after it is let go.

import "base:runtime"

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

// Player 1 flies `id` from the start of the stage, `warm` steps in. An idle
// ship is shot down about 220 steps in.
@(private = "file")
weapon_shot :: proc(s: ^sim.State, id: string, warm: int) -> string {
	loadout.loadout_of(s).shown = sim.single(s, sim.Level_Info).played
	if !loadout.loadout_give(s, 0, sim.res_id(id)) {
		return "no such weapon (is assets/extra there?)"
	}
	for _ in 0 ..< warm {
		_ = sim.session_step(s, {})
	}
	return ""
}

@(private = "file")
chaingun_shot :: proc(s: ^sim.State, name: string) -> string {
	return weapon_shot(s, "aicg", name == "chaingun_charge" ? 120 : 180)
}

@(private = "file")
discharge_shot :: proc(s: ^sim.State, name: string) -> string {
	return weapon_shot(s, "aidb", name == "discharge_charge" ? 120 : 180)
}

// Fire held for `hold` steps, then `after` without.
@(private = "file", rodata)
CHAINGUN_PHASES := []ui.Shot_Phase{{4, {{.Fire_Air}, {}}}, {6, {}}}
@(private = "file", rodata)
CHAINGUN_CHARGE_PHASES := []ui.Shot_Phase{{70, {{.Fire_Air}, {}}}, {12, {}}}
@(private = "file", rodata)
DISCHARGE_PHASES := []ui.Shot_Phase{{1, {{.Fire_Air}, {}}}, {1, {}}}
@(private = "file", rodata)
DISCHARGE_CHARGE_PHASES := []ui.Shot_Phase{{90, {{.Fire_Air}, {}}}, {1, {}}}

@(init)
register_shots :: proc "contextless" () {
	context = runtime.default_context()
	id := new_weapons.ID
	ui.shot_register({name = "loadout", plugin = id, level = 6, setup = loadout_shot})
	ui.shot_register({name = "loadout_2p", plugin = id, level = 6, co_op = true, setup = loadout_shot})
	ui.shot_register({name = "loadout_placed", plugin = id, level = 1, setup = loadout_shot})
	ui.shot_register({name = "chaingun", plugin = id, level = 6, setup = chaingun_shot, phases = CHAINGUN_PHASES})
	ui.shot_register({name = "chaingun_charge", plugin = id, level = 6, setup = chaingun_shot, phases = CHAINGUN_CHARGE_PHASES})
	ui.shot_register({name = "discharge", plugin = id, level = 9, setup = discharge_shot, phases = DISCHARGE_PHASES})
	ui.shot_register({name = "discharge_charge", plugin = id, level = 9, setup = discharge_shot, phases = DISCHARGE_CHARGE_PHASES})
}
