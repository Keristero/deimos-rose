package game

// Screens: a plugin's own screen, reached from an item on the main menu,
// and the sessions it starts and steps itself (Phase 10 stage 4,
// decisions.md D86). Netplay's lobby is one: it opens a socket, starts the
// session both peers play, and steps it through its rollback session in
// place of this machine's input. The game names no screen: it lists each
// registered one's item while its plugin is on, hands it the Flow, and
// keeps the rest -- the pause, the end of the session, the high scores --
// its own.

import "dr:render"
import "dr:sim"

MAX_SCREENS :: 4

Screen :: struct {
	plugin: sim.Plugin_ID, // its item is on the main menu while this is on
	label:  string, // the item, under the original's buttons
	// Its item was clicked; the Flow is showing it.
	open:   proc(fl: ^Flow, r: ^render.Renderer),
	// Once a render frame while it is shown.
	update: proc(fl: ^Flow, r: ^render.Renderer),
	draw:   proc(fl: ^Flow, r: ^render.Renderer),
	// Once at startup, once the Flow is ready: it may show itself
	// (screen_show), as netplay's does for DR_NETPLAY. Optional.
	launch: proc(fl: ^Flow, r: ^render.Renderer),
	// A menu-shot scenario of its own (`mise run menu-shot MENU=<name>`):
	// whether it knows `name`, having readied itself to be drawn once.
	// Optional. menu-shots:all finds the names in a `menu_shot ::`
	// procedure's cases, in a plugin's view/.
	shot:   proc(fl: ^Flow, r: ^render.Renderer, name: string) -> bool,
	// The game is closing: give back what it holds (a socket).
	close:  proc(),
	// Once a frame, once the canvas holds it: what a test of the screen's
	// saves (netplay's DR_NETPLAY_SHOT). Optional.
	framed: proc(r: ^render.Renderer),

	// A session it drives (flow_drive) rather than this machine alone:
	// once a render frame, before the game reads any key;
	poll:         proc(fl: ^Flow, r: ^render.Renderer),
	// once a step, in place of this machine's input and sim.session_step,
	// stepping the presentation after it too (flow_after_step);
	step:         proc(fl: ^Flow, r: ^render.Renderer, fx: ^render.Effects),
	// what holds it still, as a banner's two lines, "" while it plays: a
	// held session leaves on Escape and plays on alone on F5;
	banner:       proc() -> (title, sub: cstring),
	// the player at this machine;
	local_player: proc() -> int,
	// and let go: `goodbye` when the player here left it, rather than it
	// ending (flow_finish_session) or being played on alone.
	release:      proc(goodbye: bool),
	// The line under the pause menu while it is paused for everyone.
	pause_note:   string,
	// For the diagnostics overlay: the round trip, and rollbacks so far.
	stats:        proc() -> (ping_ms: f32, rollbacks: int),
}

// Called from registration steps only (sim.register_step); returns the
// screen's index, for screen_show and flow_drive.
screen_register :: proc(s: Screen) -> int {
	return sim.registry_add(&shared.screens, s)
}

registered_screens :: proc() -> []Screen {
	return sim.registry_items(&shared.screens)
}

// Shows registered screen `index`.
screen_show :: proc(fl: ^Flow, r: ^render.Renderer, index: int) {
	fl.mode, fl.screen = .Screen, index
	registered_screens()[index].open(fl, r)
}

// Plays the session in fl.state, which screen `index` has begun or
// received, as that screen steps it.
flow_drive :: proc(fl: ^Flow, index: int) {
	fl.screen, fl.driven = index, true
	fl.mode = .Playing
}

// The screen shown, or driving the session.
@(private)
flow_screen :: proc(fl: ^Flow) -> ^Screen {
	return &registered_screens()[fl.screen]
}

// For the diagnostics overlay: whether a screen drives the session, and
// what it measured.
flow_stats :: proc(fl: ^Flow) -> (driven: bool, ping_ms: f32, rollbacks: int) {
	if !fl.driven {
		return
	}
	s := flow_screen(fl)
	if s.stats != nil {
		ping_ms, rollbacks = s.stats()
	}
	return true, ping_ms, rollbacks
}

// A screen's menu shot of that name, readied; false when none knows it.
@(private)
shot_screen :: proc(fl: ^Flow, r: ^render.Renderer, name: string) -> bool {
	for s, i in registered_screens() {
		if s.shot != nil && s.shot(fl, r, name) {
			fl.mode, fl.screen = .Screen, i
			return true
		}
	}
	return false
}
