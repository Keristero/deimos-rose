package water_view

// Moving Water's screenshot scenario (ui/shots.odin), for `mise run
// menu-shot MENU=water` (and water_splash, water_splash_late for ripples): a stage with a river, some steps in. New content:
// a visual check.

import "dr:plugins/water"
import "dr:sim"
import "dr:ui"

@(private = "file")
water_shot :: proc(s: ^sim.State, name: string) -> string {
	for _ in 0 ..< 30 {
		_ = sim.session_step(s, {})
	}
	return ""
}

// One step, so the effect system has seen the level.
@(private = "file", rodata)
SETTLE := []ui.Shot_Phase{{1, {}}}

// A bomb let go over the river, and a while after it lands: the ring
// that goes out from it, and what the banks send back.
@(private = "file", rodata)
SPLASH := []ui.Shot_Phase{{45, {{.Left}, {}}}, {1, {{.Fire_Ground}, {}}}, {20, {}}, {40, {}}}
@(private = "file", rodata)
SPLASH_LATE := []ui.Shot_Phase{{45, {{.Left}, {}}}, {1, {{.Fire_Ground}, {}}}, {20, {}}, {70, {}}}

register_shots :: proc() {
	ui.shot_register({name = "water_splash", plugin = water.ID, level = 4, alone = true, setup = water_shot, phases = SPLASH})
	ui.shot_register({name = "water_splash_late", plugin = water.ID, level = 4, alone = true, setup = water_shot, phases = SPLASH_LATE})
	ui.shot_register({name = "water", plugin = water.ID, level = 4, alone = true, setup = water_shot, phases = SETTLE})
}

@(init)
register_shots_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/water/view register_shots", register_shots)
}
