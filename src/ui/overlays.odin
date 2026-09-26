package ui

// Overlays: a plugin's screen drawn over the play field while a session is
// in play, after the frame is presented -- Easy Mode's reward screen and the
// loadout. A plugin registers its own from its view/ package, so the game
// draws them without naming them. Each is drawn only in a session with its
// plugin on, and draws nothing while its screen is closed.

import "dr:render"
import "dr:sim"

MAX_OVERLAYS :: 8

// How the game names each player: their name from the netplay lobby, or
// P1 and P2.
Player_Names :: [sim.MAX_PLAYERS]string

Overlay :: struct {
	name:   string,
	plugin: sim.Plugin_ID,
	draw:   proc(r: ^render.Renderer, s: ^sim.State, names: ^Player_Names),
}

@(private = "file")
overlays: sim.Registry(Overlay, MAX_OVERLAYS)

// Called from `@(init)` procedures only.
overlay_register :: proc(o: Overlay) {
	sim.registry_add(&overlays, o)
}

overlays_draw :: proc(r: ^render.Renderer, s: ^sim.State, names: ^Player_Names) {
	for &o in sim.registry_items(&overlays) {
		if sim.mod_on(s, o.plugin) {
			o.draw(r, s, names)
		}
	}
}
