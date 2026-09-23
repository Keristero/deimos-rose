package game

// Command-line switches for how the game presents itself, as opposed to what
// the simulation does -- the simulation takes no settings at all. See
// notes/user-guidance-mid-phase5.md and docs/decisions.md D16/D17.
Settings :: struct {
	// -classic: prefer matching the original's look exactly over a nicer
	// alternative, wherever the two are ever in tension. Off by default: a
	// choice that makes the game look better without changing what it does
	// is worth keeping (D16). Nothing reads this yet -- it exists so Stage 3
	// onward has somewhere to put a fidelity decision as one comes up,
	// rather than that decision only ever getting the one answer.
	classic: bool,
	// -highrefreshrate: present at the monitor's native refresh rate instead
	// of the original's fixed 30 FPS. The simulation still steps at a fixed
	// 30 Hz regardless (D17) -- this only changes how often an already-built
	// frame gets redrawn.
	high_refresh_rate: bool,
	// -diagnostics: a small rolling-stats overlay in the bottom-right corner
	// (game/diagnostics.odin) -- FPS always, plus (in a netplay session)
	// ping, rollbacks/sec and updates/sec. New content, no original
	// equivalent -- notes/netcode-enhancements.md asked for it.
	diagnostics: bool,
}

settings_parse :: proc(args: []string) -> (s: Settings) {
	for a in args[1:] {
		switch a {
		case "-classic":
			s.classic = true
		case "-highrefreshrate":
			s.high_refresh_rate = true
		case "-diagnostics":
			s.diagnostics = true
		}
	}
	return
}
