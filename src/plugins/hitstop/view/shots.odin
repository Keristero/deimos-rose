package hitstop_view

// Hitstop's screenshot scenario (ui/shots.odin), for `mise run menu-shot
// MENU=hitstop`: stage 7 with the kill cam started on a point above the
// player, held part-way through by DR_HITSTOP_AT=<0..1> (0.5 when unset: the
// zoom close and the text up). New content: a visual check. The cam is
// started by hand because the stage has no unit to take down.

import "core:os"
import "core:strconv"

import "dr:plugins/hitstop"
import "dr:sim"
import "dr:ui"

@(private = "file")
hitstop_shot :: proc(s: ^sim.State, name: string) -> string {
	for _ in 0 ..< 60 {
		_ = sim.session_step(s, {})
	}
	at, ok := strconv.parse_f32(os.get_env("DR_HITSTOP_AT", context.temp_allocator))
	cam_hold_at(sim.player_at(s, 0).loc + {0, -60}, ok ? at : 0.5)
	return ""
}

@(private = "file", rodata)
ONE_STEP := []ui.Shot_Phase{{1, {}}}

register_shots :: proc() {
	ui.shot_register({name = "hitstop", plugin = hitstop.ID, level = 6, alone = true, setup = hitstop_shot, phases = ONE_STEP})
}

@(init)
register_shots_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/hitstop/view register_shots", register_shots)
}
