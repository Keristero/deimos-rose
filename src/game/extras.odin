package game

// Mods and their settings: features the original never had. Each is a
// plugin (sim/plugins.odin) the player turns on from the Mods page
// (game/menu_mods.odin); the settings the mods register (prefs/settings.odin)
// are on the Extras page below. The rule they all follow is that classic
// mode is the original game -- same look, same behaviour -- so every mod
// reads as off there, whatever is saved. Code that implements one asks
// prefs_mod_on, setting_on and setting_value and nothing else.

import rl "vendor:raylib"

import "dr:prefs"
import "dr:render"
import "dr:sim"
import "dr:ui"

// The mods in effect: the saved ones whose dependencies are all on, and
// none in classic mode. A plugin's launch switch turns it on for the run,
// and -campaign its campaign (launch.odin).
prefs_mods :: proc(ps: ^Prefs_State) -> sim.Mods {
	if prefs_classic(ps) {
		return {}
	}
	mods := ps.saved.mods
	mods = sim.mods_switch_on(mods, ps.launch_mods)
	if id, ok := launch_campaign(ps.launch); ok && id != sim.CORE {
		mods = sim.mods_switch_on(mods, {int(id)})
	}
	return sim.mods_resolve(mods)
}

prefs_mod_on :: proc(ps: ^Prefs_State, id: sim.Plugin_ID) -> bool {
	return int(id) in prefs_mods(ps)
}

// Whether the player has an online plugin on (Plugin.online): the main
// menu then offers NETPLAY.
prefs_online_on :: proc(ps: ^Prefs_State) -> bool {
	return prefs_mods(ps) & sim.mods_online() != {}
}

// Turns a mod on with its dependencies, or off with its dependants, and
// saves.
prefs_mod_toggle :: proc(ps: ^Prefs_State, id: sim.Plugin_ID) {
	if ps.launch_mods != {} {
		// The menu now shows and controls what is live.
		ps.saved.mods = sim.mods_switch_on(ps.saved.mods, ps.launch_mods)
		ps.launch_mods = {}
	}
	prefs.mod_toggle(&ps.saved.mods, id)
	prefs_state_save(ps)
}

// A switch for a mod and what comes with it: turned on, the mod brings back
// its default-on dependants too (the lobby's New Weapons brings the
// Chaingun); turned off, it takes them all, as any mod does.
prefs_mod_toggle_group :: proc(ps: ^Prefs_State, id: sim.Plugin_ID) {
	prefs_mod_toggle(ps, id)
	if int(id) in ps.saved.mods {
		for d in sim.mods_default_dependants(id) {
			prefs_mod_set(ps, sim.Plugin_ID(d), true)
		}
	}
}

// Switches a mod on or off, leaving it as it is when it already is.
prefs_mod_set :: proc(ps: ^Prefs_State, id: sim.Plugin_ID, on: bool) {
	if (int(id) in ps.saved.mods) != on {
		prefs_mod_toggle(ps, id)
	}
}

// Whether a toggle setting is on and in effect: its mod is on.
setting_on :: proc(ps: ^Prefs_State, id: prefs.Setting_ID) -> bool {
	return prefs_mod_on(ps, prefs.registered_settings()[id].plugin) && ps.saved.settings[id] != 0
}

// The saved value, whether or not it is in effect (a hue for the lobby to
// send, say).
setting_value :: proc(ps: ^Prefs_State, id: prefs.Setting_ID) -> int {
	return ps.saved.settings[id]
}

setting_set :: proc(ps: ^Prefs_State, id: prefs.Setting_ID, v: int) {
	ps.saved.settings[id] = prefs.setting_clean(id, v)
	prefs_state_save(ps)
}

@(private = "file") EXTRAS_TITLE_Y :: 34
@(private = "file") EXTRAS_ROW0_Y :: 90
@(private = "file") EXTRAS_ROW :: 44
@(private = "file") EXTRAS_ROWS_SHOWN :: 7
@(private = "file") EXTRAS_LABEL_X :: 110
@(private = "file") EXTRAS_VALUE_X :: 350 // centre of a toggle; a slider spans either side
@(private = "file") EXTRAS_SLIDER_W :: 150
@(private = "file") EXTRAS_SCROLL_X :: 440
@(private = "file") EXTRAS_BACK_Y :: 436
@(private = "file") EXTRAS_NOTE_Y :: 404
@(private = "file") EXTRAS_RESET_X :: 510

Extras_Page :: struct {
	scroll:  ui.Scroll_Rows,
	toggles: [prefs.MAX_SETTINGS]ui.Text_Button,
	back:    ui.Text_Button,
	reset:   ui.Text_Button, // the sliders back to their defaults
}

// The settings listed: those of the saved mods, dimmed but still there in
// classic mode, so the page shows what classic mode switched off.
@(private = "file")
extras_listed :: proc(ps: ^Prefs_State, out: ^[prefs.MAX_SETTINGS]prefs.Setting_ID) -> []prefs.Setting_ID {
	mods := sim.mods_resolve(ps.saved.mods)
	n := 0
	for s, id in prefs.registered_settings() {
		if int(s.plugin) in mods {
			out[n] = prefs.Setting_ID(id)
			n += 1
		}
	}
	return out[:n]
}

// Whether the page has sliders for the reset button to act on.
@(private = "file")
extras_has_sliders :: proc(listed: []prefs.Setting_ID) -> bool {
	for id in listed {
		if prefs.registered_settings()[id].kind == .Percent {
			return true
		}
	}
	return false
}

// Puts every listed slider (not the toggles or the colours) back to its
// default, and saves.
@(private = "file")
extras_reset_sliders :: proc(ps: ^Prefs_State, listed: []prefs.Setting_ID) {
	settings := prefs.registered_settings()
	for id in listed {
		if settings[id].kind == .Percent {
			ps.saved.settings[id] = prefs.setting_clean(id, settings[id].default)
		}
	}
	prefs_state_save(ps)
}

// Where the listed setting at `row` sits on the page; false when it is
// scrolled out of sight.
@(private = "file")
extras_row_y :: proc(x: ^Extras_Page, row: int) -> (f32, bool) {
	shown := row - x.scroll.first
	return EXTRAS_ROW0_Y + f32(shown) * EXTRAS_ROW, shown >= 0 && shown < EXTRAS_ROWS_SHOWN
}

@(private = "file")
extras_slider_rect :: proc(y: f32) -> rl.Rectangle {
	return {EXTRAS_VALUE_X - EXTRAS_SLIDER_W / 2, y + 6, EXTRAS_SLIDER_W, ui.HUE_SLIDER_H}
}

// Toggles show their live value, so they are re-laid each frame.
@(private = "file")
extras_page_layout :: proc(r: ^render.Renderer, x: ^Extras_Page, ps: ^Prefs_State, listed: []prefs.Setting_ID) {
	settings := prefs.registered_settings()
	for id, row in listed {
		y, shown := extras_row_y(x, row)
		if shown && settings[id].kind == .Toggle {
			ui.text_button_relabel(r, &x.toggles[id], ps.saved.settings[id] != 0 ? "ON" : "OFF", EXTRAS_VALUE_X, y)
		}
	}
	ui.text_button_relabel(r, &x.back, "BACK", render.SCREEN_W / 2, EXTRAS_BACK_Y)
	ui.text_button_relabel(r, &x.reset, "RESET SLIDERS", EXTRAS_RESET_X, EXTRAS_BACK_Y)
}

// Returns true when the page is left (Back or Escape).
extras_page_update :: proc(r: ^render.Renderer, x: ^Extras_Page, ps: ^Prefs_State) -> (leave: bool) {
	buf: [prefs.MAX_SETTINGS]prefs.Setting_ID
	listed := extras_listed(ps, &buf)
	ui.scroll_rows_update(&x.scroll, len(listed), EXTRAS_ROWS_SHOWN)
	extras_page_layout(r, x, ps, listed)
	mouse := ui.menu_mouse_pos()
	dt := rl.GetFrameTime()
	settings := prefs.registered_settings()
	for id, row in listed {
		y, shown := extras_row_y(x, row)
		if !shown {
			continue
		}
		switch settings[id].kind {
		case .Percent:
			v := ps.saved.settings[id]
			if ui.percent_slider_update(&v, extras_slider_rect(y), true) {
				ps.saved.settings[id] = v // saved once the drag ends, like a hue
			}
			if rl.IsMouseButtonReleased(.LEFT) || rl.IsKeyReleased(.LEFT) || rl.IsKeyReleased(.RIGHT) {
				prefs_state_save(ps)
			}
		case .Toggle:
			if ui.text_button_update(r, &x.toggles[id], mouse, dt) {
				setting_set(ps, id, 1 - ps.saved.settings[id])
			}
		case .Hue:
			hue := ps.saved.settings[id]
			if ui.hue_slider_update(&hue, extras_slider_rect(y), true) {
				ps.saved.settings[id] = hue // saved once the drag ends, not every frame of it
			}
			if rl.IsMouseButtonReleased(.LEFT) || rl.IsKeyReleased(.LEFT) || rl.IsKeyReleased(.RIGHT) {
				prefs_state_save(ps)
			}
		}
	}
	if extras_has_sliders(listed) && ui.text_button_update(r, &x.reset, mouse, dt) {
		extras_reset_sliders(ps, listed)
	}
	return ui.text_button_update(r, &x.back, mouse, dt) || rl.IsKeyPressed(.ESCAPE)
}

extras_page_draw :: proc(r: ^render.Renderer, x: ^Extras_Page, ps: ^Prefs_State) {
	buf: [prefs.MAX_SETTINGS]prefs.Setting_ID
	listed := extras_listed(ps, &buf)
	extras_page_layout(r, x, ps, listed)
	ui.menu_draw_background(r, "back")
	white := rl.Color{255, 255, 255, 255}
	dim := rl.Color{190, 190, 190, 255}
	header := rl.Color{ui.HIGH_SCORES_HEADER_RGB[0], ui.HIGH_SCORES_HEADER_RGB[1], ui.HIGH_SCORES_HEADER_RGB[2], 255}
	classic := prefs_classic(ps)

	ui.menu_draw_text(r, "EXTRAS", render.SCREEN_W / 2, EXTRAS_TITLE_Y, header, .Centre)
	settings := prefs.registered_settings()
	for id, row in listed {
		y, shown := extras_row_y(x, row)
		if !shown {
			continue
		}
		ui.menu_draw_text(r, settings[id].label, EXTRAS_LABEL_X, i32(y) + 5, classic ? dim : white)
		switch settings[id].kind {
		case .Toggle:
			ui.text_button_draw(r, &x.toggles[id])
		case .Percent:
			ui.percent_slider_draw(ps.saved.settings[id], extras_slider_rect(y), classic)
		case .Hue:
			ui.hue_slider_draw(ps.saved.settings[id], extras_slider_rect(y), classic)
		}
	}
	ui.scroll_rows_draw(&x.scroll, len(listed), EXTRAS_ROWS_SHOWN, EXTRAS_SCROLL_X, EXTRAS_ROW0_Y, EXTRAS_ROWS_SHOWN * EXTRAS_ROW - 20)
	saved := sim.mods_resolve(ps.saved.mods)
	for &pv in ui.registered_settings_previews() {
		if int(pv.plugin) in saved {
			pv.draw(r, &ps.saved.settings, prefs_mod_on(ps, pv.plugin))
		}
	}
	note: string
	switch {
	case classic:
		note = "CLASSIC MODE IS ON: MODS ARE OFF UNTIL IT IS TURNED OFF"
	case len(listed) == 0:
		note = "NONE OF THE MODS THAT ARE ON HAVE SETTINGS"
	case:
		note = "SETTINGS FOR THE MODS THAT ARE ON -- NONE APPLY IN CLASSIC MODE"
	}
	ui.menu_draw_text(r, note, render.SCREEN_W / 2, EXTRAS_NOTE_Y, dim, .Centre)
	if extras_has_sliders(listed) {
		ui.text_button_draw(r, &x.reset)
	}
	ui.text_button_draw(r, &x.back)
}

// Whether the Extras page can be opened: the plugin that offers it
// (prefs.settings_page_register) is on.
extras_available :: proc(ps: ^Prefs_State) -> bool {
	page := prefs.settings_page_plugin()
	return page != sim.CORE && int(page) in sim.mods_resolve(ps.saved.mods)
}

// Player `n`'s colour (0 or 1), as saved (prefs.Setting.player); 0 when
// no plugin registers one.
player_hue :: proc(ps: ^Prefs_State, n: int) -> int {
	id, ok := prefs.player_hue_setting(n + 1)
	return ok ? ps.saved.settings[id] : 0
}

// Sets player 1's colour (yours in netplay), where a plugin registers one.
player_hue_set :: proc(ps: ^Prefs_State, hue: int) {
	if id, ok := prefs.player_hue_setting(1); ok {
		ps.saved.settings[id] = hue
	}
}

// Whether players are drawn in their colours: the plugin of the colour
// settings is on.
player_colours_on :: proc(ps: ^Prefs_State) -> bool {
	id, ok := prefs.player_hue_setting(1)
	return ok && prefs_mod_on(ps, prefs.registered_settings()[id].plugin)
}
