package netplay_plugin

// Named apart from its folder: net/ is package netplay, and package names
// must be unique.

import "base:runtime"
import _ "dr:sim/core"
import "dr:sim"

// Netplay's pause: new content, not the original's G_Interface_PauseGame,
// which lives outside the simulation entirely (game/flow.odin's .Paused,
// still what a local session uses). Either player's Pause press toggles
// it, for both peers at once, since it is part of the simulation.

// On the session entity.
Pause :: struct {
	paused: bool,
	held:   [sim.MAX_PLAYERS]bool, // each player's Pause bit last step, for edge detection
}

// The session's pause; nil when netplay is not on.
pause_of :: #force_inline proc "contextless" (s: ^sim.State) -> ^Pause {
	return sim.get(s.ecs, sim.SESSION_ENTITY, Pause)
}

// Whether the session is paused.
paused :: proc "contextless" (s: ^sim.State) -> bool {
	p := pause_of(s)
	return p != nil && p.paused
}

// While paused only the frame count moves, which the rollback ring is keyed
// on; inputs keep flowing so that either player can unpause. The game never
// sees the Pause button.
@(private = "file")
pause_system :: proc(s: ^sim.State, step: ^sim.Step) {
	pause := pause_of(s)
	toggle := false
	for i in 0 ..< sim.MAX_PLAYERS {
		held := .Pause in step.input[i]
		if held && !pause.held[i] {
			toggle = true // both pressing on the same frame still toggles once
		}
		pause.held[i] = held
	}
	if toggle {
		pause.paused = !pause.paused
	}
	if pause.paused {
		sim.clear_step_events(s) // nothing happened this step; do not replay last step's
		sim.single(s, sim.Clock).frame += 1
		step.done = true
		return
	}
	for &b in step.input {
		b -= {.Pause}
	}
}

@(private = "file")
setup_system :: proc(s: ^sim.State, step: ^sim.Step) {
	sim.add(s.ecs, sim.SESSION_ENTITY, Pause{})
}

@(private = "file")
held :: proc "contextless" (s: ^sim.State) -> bool {
	return pause_of(s).paused
}

ID: sim.Plugin_ID

// First of all, ahead of the game step and anything else around it.
@(private = "file", rodata)
BEFORE := []string{"step_events"}

// Its components go on the session's entities once they exist, and before
// the players are set up with them.
@(private = "file", rodata)
SETUP_AFTER := []string{"session_setup"}
@(private = "file", rodata)
SETUP_BEFORE := []string{"players_setup"}

@(init)
register :: proc "contextless" () {
	context = runtime.default_context()
	ID = sim.plugin_register({
		name        = "netplay",
		label       = "NETPLAY",
		description = "Two players over the network, with rollback",
		session     = true,
		default_on  = true,
	})
	sim.component_register(Pause, 1)
	sim.system_register({name = "netplay_setup", after = SETUP_AFTER, before = SETUP_BEFORE, plugin = ID, kind = .Setup, run = setup_system})
	sim.system_register({name = "netplay_pause", before = BEFORE, plugin = ID, kind = .Session, run = pause_system})
	sim.hold_register({plugin = ID, held = held})
}
