package game

import "core:fmt"
import "core:strings"

import rl "vendor:raylib"

import "dr:render"
import "dr:sim"
import "dr:ui"

// A row of the setup switches plugins register for one screen
// (ui.setup_switch_register): Level Select's and the lobby's.
Setup_Switches :: struct {
	buttons: [ui.MAX_SETUP_SWITCHES]ui.Text_Button,
	plugins: [ui.MAX_SETUP_SWITCHES]sim.Plugin_ID,
	count:   int,
}

// A plugin's switch label: "EASY MODE: ON".
mod_label :: proc(mods: sim.Mods, id: sim.Plugin_ID) -> string {
	return fmt.tprintf("%s: %s", sim.registered_plugins()[id].label, int(id) in mods ? "ON" : "OFF")
}

// Lays the screen's switches out on row `y`, labelled with `mods`. They
// show their live value, so they are re-laid each frame.
setup_switches_layout :: proc(r: ^render.Renderer, sw: ^Setup_Switches, screen: ui.Setup_Screen, mods: sim.Mods, y: f32) {
	sw.count = 0
	for s in ui.registered_setup_switches() {
		if screen in s.screens {
			sw.plugins[sw.count] = s.plugin
			sw.count += 1
		}
	}
	for i in 0 ..< sw.count {
		ui.text_button_relabel(r, &sw.buttons[i], mod_label(mods, sw.plugins[i]), ui.setup_switch_x(i, sw.count), y)
	}
}

// Turns a clicked switch's plugin on or off, with what comes with it.
setup_switches_update :: proc(fl: ^Flow, r: ^render.Renderer, sw: ^Setup_Switches, mouse: rl.Vector2, dt: f32) {
	for i in 0 ..< sw.count {
		if ui.text_button_update(r, &sw.buttons[i], mouse, dt) {
			prefs_mod_toggle_group(fl.prefs, sw.plugins[i])
		}
	}
}

setup_switches_draw :: proc(r: ^render.Renderer, sw: ^Setup_Switches) {
	for i in 0 ..< sw.count {
		ui.text_button_draw(r, &sw.buttons[i])
	}
}

// The switches' labels in one line, for a player who cannot change them.
setup_switches_text :: proc(sw: ^Setup_Switches, mods: sim.Mods) -> string {
	labels: [ui.MAX_SETUP_SWITCHES]string
	for i in 0 ..< sw.count {
		labels[i] = mod_label(mods, sw.plugins[i])
	}
	return strings.join(labels[:sw.count], "  --  ", context.temp_allocator)
}
