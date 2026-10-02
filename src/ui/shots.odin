package ui

// Shots: a plugin's own screenshot scenarios for `mise run menu-shot
// MENU=<name>` (game/main.odin, run_menu_shot), registered from its view/
// package so the game renders them without naming the plugin or its
// content. Each is a session outside classic mode with its plugin on, and
// the default mods unless `alone` -- never the player's own Mods page, so
// a shot looks the same on every machine:
// `setup` readies it -- steps it, hands a player a weapon, opens a screen
// -- and then each phase holds its buttons for its steps while the
// presentation (particles and effect systems) follows, so a shot fired in
// a phase is drawn. One frame is taken at the end.

import "dr:sim"

MAX_SHOTS :: 32

Shot_Phase :: struct {
	steps: int,
	input: sim.Frame_Input,
}

Shot :: struct {
	name:   string,
	plugin: sim.Plugin_ID, // turned on, with what it needs
	level:  int,           // index into the level list the session starts at
	co_op:  bool,
	// Only its plugin and what it needs, without the other mods that are
	// on by default (a Level Select start with the Mods page untouched).
	alone:  bool,
	// Called once the session has started; a message fails the shot.
	setup:  proc(s: ^sim.State, name: string) -> (err: string),
	phases: []Shot_Phase,
}

@(private = "file")
shots: sim.Registry(Shot, MAX_SHOTS)

// Called from registration steps only (sim.register_step); `phases` must outlive the call.
shot_register :: proc(sh: Shot) {
	sim.registry_add(&shots, sh)
}

shot_find :: proc(name: string) -> (^Shot, bool) {
	for &sh in sim.registry_items(&shots) {
		if sh.name == name {
			return &sh, true
		}
	}
	return nil, false
}

registered_shots :: proc() -> []Shot {
	return sim.registry_items(&shots)
}
