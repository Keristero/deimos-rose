package lighting_view

// Realtime Lighting's screenshot scenarios (ui/shots.odin), for `mise run
// menu-shot MENU=lighting`: stage 7 with a shot let go a few steps ago, so it and
// sparks are in the air. New content: a visual check. Compare with the same
// stage with the plugin off, and in classic mode, which must not differ.

import "dr:plugins/lighting"
import "dr:sim"
import "dr:ui"

@(private = "file")
lighting_shot :: proc(s: ^sim.State, name: string) -> string {
	for _ in 0 ..< 60 {
		_ = sim.session_step(s, {})
	}
	return ""
}

@(private = "file", rodata)
FIRING := []ui.Shot_Phase{{4, {{.Fire_Air}, {}}}, {3, {}}}

register_shots :: proc() {
	ui.shot_register({name = "lighting", plugin = lighting.ID, level = 6, alone = true, setup = lighting_shot, phases = FIRING})
}

@(init)
register_shots_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/lighting/view register_shots", register_shots)
}
