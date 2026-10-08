package lighting_view

// Realtime Lighting's screenshot scenarios (ui/shots.odin), for `mise run
// menu-shot MENU=lighting`: stage 7 with a shot let go a few steps ago, so it and
// sparks are in the air. New content: a visual check. Compare with the same
// stage with the plugin off, and in classic mode, which must not differ.

import "dr:plugins/lighting"
import "dr:prefs"
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

@(private = "file", rodata)
BOMB_LAUNCH := []ui.Shot_Phase{{1, {{.Fire_Ground}, {}}}, {3, {}}}
@(private = "file", rodata)
BOMB_MID := []ui.Shot_Phase{{1, {{.Fire_Ground}, {}}}, {10, {}}}
@(private = "file", rodata)
BOMB_LANDING := []ui.Shot_Phase{{1, {{.Fire_Ground}, {}}}, {21, {}}}

@(private = "file", rodata)
BOMB_SHADOW := []ui.Shot_Phase{{15, {{.Left}, {}}}, {1, {{.Fire_Ground}, {}}}, {21, {}}}

register_shots :: proc() {
	id := lighting.id()
	ui.shot_register({name = "lighting", plugin = id, level = 6, alone = true, setup = lighting_shot, phases = FIRING})
	ui.shot_register({name = "lighting_bomb_launch", plugin = id, level = 6, alone = true, setup = lighting_shot, phases = BOMB_LAUNCH})
	ui.shot_register({name = "lighting_bomb_mid", plugin = id, level = 6, alone = true, setup = lighting_shot, phases = BOMB_MID})
	ui.shot_register({name = "lighting_bomb_landing", plugin = id, level = 6, alone = true, setup = lighting_shot, phases = BOMB_LANDING})
	ui.shot_register({name = "lighting_bomb_shadow", plugin = id, level = 6, alone = true, setup = lighting_shot, phases = BOMB_SHADOW})
	// The Extras page with Realtime Lighting on, so its sliders and the
	// button that puts them back show; the glow is moved off its default.
	ui.menu_shot_register({name = "preferences_extras_sliders", plugin = id, screen = "extras", setup = sliders_shot_setup})
}

@(private = "file")
sliders_shot_setup :: proc(p: ^prefs.Prefs) {
	p.settings[shared.glow_strength] = 80
}

@(init)
register_shots_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/lighting/view register_shots", register_shots)
}
