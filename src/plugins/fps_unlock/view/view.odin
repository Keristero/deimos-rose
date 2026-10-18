package fps_unlock_view

import rl "vendor:raylib"

import "dr:plugins/fps_unlock"
import "dr:prefs"
import "dr:render"
import "dr:sim"

// 30FPS Unlock's presentation: the display's own refresh rate in place of
// the original's 30 frames a second, and -highrefreshrate, which turns it
// on for one run.

register :: proc() {
	render.frame_rate_register({plugin = fps_unlock.id(), fps = display_rate})
	prefs.launch_switch_register({flag = "-highrefreshrate", plugin = fps_unlock.id()})
}

@(init)
register_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/fps_unlock/view register", register)
}

// The monitor's refresh rate, or 60 where it cannot say.
@(private = "file")
display_rate :: proc() -> i32 {
	rate := rl.GetMonitorRefreshRate(rl.GetCurrentMonitor())
	return rate > 0 ? rate : 60
}
