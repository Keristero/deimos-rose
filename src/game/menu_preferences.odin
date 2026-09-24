package game

// The Preferences screen, reached from the main menu's Preferences button:
// per-player key bindings, sound and music volume, fullscreen, the
// diagnostics overlay and classic mode, plus the Extras page
// (game/extras.odin) for everything the original did not have. New content -- the original's
// Preferences was a native Win32 dialog with no art to port -- so it is
// built from Text_Buttons like the netplay lobby, not traced plates.
//
// Every change is saved as it is made (prefs_state_save); there is no
// apply/cancel step. main.odin copies the live values into the renderer,
// audio and window each frame, so each takes effect immediately.
//
// Deliberately still reachable under classic mode (unlike Netplay): it is
// the only way to turn classic mode back off from inside the game (D30).

import "core:fmt"

import rl "vendor:raylib"

import "dr:prefs"
import "dr:sim"

@(private = "file") PREFS_TITLE_Y :: 34
@(private = "file") PREFS_PLAYER_Y :: 64
@(private = "file") PREFS_KEYS_Y :: 92
@(private = "file") PREFS_ROW :: 22
@(private = "file") PREFS_RESET_Y :: 270
@(private = "file") PREFS_OPTIONS_Y :: 300
@(private = "file") PREFS_BACK_Y :: 436
@(private = "file") PREFS_STATUS_Y :: 462

@(private = "file") PREFS_LABEL_X :: 130  // left edge of each row's name
@(private = "file") PREFS_VALUE_X :: 410  // centre of each row's value
@(private = "file") PREFS_ARROW_DX :: 90  // "<" and ">" either side of a value
@(private = "file") PREFS_SLOT_X :: [prefs.BINDING_SLOTS]f32{350, 470}

@(private = "file")
BUTTON_NAMES := [prefs.Action]string {
	.Up          = "UP",
	.Down        = "DOWN",
	.Left        = "LEFT",
	.Right       = "RIGHT",
	.Fire_Air    = "FIRE AIR",
	.Fire_Ground = "FIRE GROUND",
	.Change_Air  = "CHANGE WEAPON",
}

@(private = "file")
Option :: enum {
	Sound,
	Music,
	Display,
	Diagnostics,
	Classic,
	Extras,
}

@(private = "file")
OPTION_NAMES := [Option]string {
	.Sound       = "SOUND VOLUME",
	.Music       = "MUSIC VOLUME",
	.Display     = "DISPLAY",
	.Diagnostics = "DIAGNOSTICS",
	.Classic     = "CLASSIC MODE",
	.Extras      = "EXTRAS",
}

Preferences :: struct {
	player: int, // whose bindings are shown, 0-based
	extras_open: bool, // showing the Extras page instead
	extras:      Extras_Page,

	// Waiting for a key for this binding slot, after its button was clicked.
	capturing:      bool,
	capture_button: prefs.Action,
	capture_slot:   int,

	player_prev, player_next: Text_Button,
	keys:                     [prefs.Action][prefs.BINDING_SLOTS]Text_Button,
	reset:                    Text_Button,
	volume_down, volume_up:   [Option]Text_Button, // only .Sound and .Music use these
	toggle:                   [Option]Text_Button, // .Display/.Diagnostics/.Classic, and the volume readouts
	back:                     Text_Button,
}

preferences_init :: proc(p: ^Preferences) {
	p^ = {}
}

@(private = "file")
option_y :: proc(o: Option) -> f32 {
	return PREFS_OPTIONS_Y + f32(o) * PREFS_ROW
}

@(private = "file")
option_value :: proc(ps: ^Prefs_State, o: Option) -> string {
	on_off :: proc(b: bool) -> string {return b ? "ON" : "OFF"}
	switch o {
	case .Sound:
		return fmt.tprintf("%d%%", ps.saved.sfx_volume)
	case .Music:
		return fmt.tprintf("%d%%", ps.saved.music_volume)
	case .Display:
		return prefs_fullscreen(ps) ? "FULLSCREEN" : "WINDOWED"
	case .Diagnostics:
		return on_off(prefs_diagnostics(ps))
	case .Classic:
		return on_off(prefs_classic(ps))
	case .Extras:
		return "OPEN"
	}
	return ""
}

// Labels show live values (key names, volumes), so every button is
// re-centred on its current label each frame before hit-testing.
@(private = "file")
preferences_layout :: proc(r: ^Renderer, p: ^Preferences, ps: ^Prefs_State) {
	text_button_relabel(r, &p.player_prev, "<", PREFS_VALUE_X - PREFS_ARROW_DX, PREFS_PLAYER_Y)
	text_button_relabel(r, &p.player_next, ">", PREFS_VALUE_X + PREFS_ARROW_DX, PREFS_PLAYER_Y)
	slot_x := PREFS_SLOT_X
	for button in prefs.Action {
		y := PREFS_KEYS_Y + f32(button) * PREFS_ROW
		for slot in 0 ..< prefs.BINDING_SLOTS {
			label := key_name(ps.saved.bindings[p.player][button][slot])
			if p.capturing && p.capture_button == button && p.capture_slot == slot {
				label = "PRESS A KEY"
			}
			text_button_relabel(r, &p.keys[button][slot], label, slot_x[slot], y)
		}
	}
	text_button_relabel(r, &p.reset, fmt.tprintf("RESET PLAYER %d KEYS", p.player + 1), SCREEN_W / 2, PREFS_RESET_Y)
	for o in Option {
		y := option_y(o)
		text_button_relabel(r, &p.toggle[o], option_value(ps, o), PREFS_VALUE_X, y)
		if o == .Sound || o == .Music {
			text_button_relabel(r, &p.volume_down[o], "<", PREFS_VALUE_X - PREFS_ARROW_DX, y)
			text_button_relabel(r, &p.volume_up[o], ">", PREFS_VALUE_X + PREFS_ARROW_DX, y)
		}
	}
	text_button_relabel(r, &p.back, "BACK", SCREEN_W / 2, PREFS_BACK_Y)
}

// Called once per render frame from flow_handle_input's .Preferences case.
preferences_update :: proc(fl: ^Flow, r: ^Renderer, p: ^Preferences) {
	ps := fl.prefs
	if p.extras_open {
		if extras_page_update(r, &p.extras, ps) {
			p.extras_open = false
		}
		return
	}
	preferences_layout(r, p, ps)

	if p.capturing {
		preferences_capture(p, ps)
		return
	}

	mouse := menu_mouse_pos()
	dt := rl.GetFrameTime()

	prev := text_button_update(r, &p.player_prev, mouse, dt)
	next := text_button_update(r, &p.player_next, mouse, dt)
	if prev || next {
		p.player = (p.player + (next ? 1 : sim.MAX_PLAYERS - 1)) % sim.MAX_PLAYERS
	}
	for button in prefs.Action {
		for slot in 0 ..< prefs.BINDING_SLOTS {
			if text_button_update(r, &p.keys[button][slot], mouse, dt) {
				p.capturing, p.capture_button, p.capture_slot = true, button, slot
			}
		}
	}
	if text_button_update(r, &p.reset, mouse, dt) {
		// Re-bound one key at a time so any default the other player has
		// since taken is moved back, not left bound twice.
		d := prefs.defaults()
		for keys, button in d.bindings[p.player] {
			for k, slot in keys {
				prefs.bind(&ps.saved, p.player, button, slot, k)
			}
		}
		prefs_state_save(ps)
	}

	for o in Option {
		switch o {
		case .Sound, .Music:
			v := o == .Sound ? &ps.saved.sfx_volume : &ps.saved.music_volume
			if text_button_update(r, &p.volume_down[o], mouse, dt) {
				prefs.step_volume(v, -1)
				prefs_state_save(ps)
			}
			if text_button_update(r, &p.volume_up[o], mouse, dt) {
				prefs.step_volume(v, 1)
				prefs_state_save(ps)
			}
			_ = update_hover_click(p.toggle[o].rect, &p.toggle[o].hover_time, mouse, dt) // a readout: hilites, but silent
		case .Display:
			if text_button_update(r, &p.toggle[o], mouse, dt) {
				prefs_set_fullscreen(ps, !prefs_fullscreen(ps))
			}
		case .Extras:
			if text_button_update(r, &p.toggle[o], mouse, dt) {
				p.extras_open = true
			}
		case .Diagnostics:
			if text_button_update(r, &p.toggle[o], mouse, dt) {
				prefs_set_diagnostics(ps, !prefs_diagnostics(ps))
			}
		case .Classic:
			if text_button_update(r, &p.toggle[o], mouse, dt) {
				prefs_set_classic(ps, !prefs_classic(ps))
			}
		}
	}

	if text_button_update(r, &p.back, mouse, dt) || rl.IsKeyPressed(.ESCAPE) {
		fl.mode = .Title
	}
}

// The first key pressed after a binding's button was clicked becomes that
// binding. Escape cancels and Backspace clears the slot, so neither can be
// bound -- both are needed to operate this screen from the keyboard. A
// click anywhere also cancels.
@(private = "file")
preferences_capture :: proc(p: ^Preferences, ps: ^Prefs_State) {
	if rl.IsMouseButtonPressed(.LEFT) || rl.IsMouseButtonPressed(.RIGHT) {
		p.capturing = false
		return
	}
	key := rl.GetKeyPressed()
	#partial switch key {
	case .KEY_NULL:
		return
	case .ESCAPE:
	case .BACKSPACE:
		prefs.bind(&ps.saved, p.player, p.capture_button, p.capture_slot, prefs.KEY_NONE)
		prefs_state_save(ps)
	case:
		prefs.bind(&ps.saved, p.player, p.capture_button, p.capture_slot, i32(key))
		prefs_state_save(ps)
	}
	p.capturing = false
}

preferences_draw :: proc(r: ^Renderer, p: ^Preferences, ps: ^Prefs_State) {
	if p.extras_open {
		extras_page_draw(r, &p.extras, ps)
		return
	}
	menu_draw_background(r, "back")
	white := rl.Color{255, 255, 255, 255}
	dim := rl.Color{190, 190, 190, 255}
	header := rl.Color{HIGH_SCORES_HEADER_RGB[0], HIGH_SCORES_HEADER_RGB[1], HIGH_SCORES_HEADER_RGB[2], 255}

	menu_draw_text(r, "PREFERENCES", SCREEN_W / 2, PREFS_TITLE_Y, header, .Centre)

	menu_draw_text(r, "CONTROLS FOR", PREFS_LABEL_X, PREFS_PLAYER_Y + 5, header)
	menu_draw_text(r, fmt.tprintf("PLAYER %d", p.player + 1), PREFS_VALUE_X, PREFS_PLAYER_Y + 5, white, .Centre)
	text_button_draw(r, &p.player_prev)
	text_button_draw(r, &p.player_next)

	for button in prefs.Action {
		y := PREFS_KEYS_Y + i32(button) * PREFS_ROW
		menu_draw_text(r, BUTTON_NAMES[button], PREFS_LABEL_X, y + 5, white)
		for slot in 0 ..< prefs.BINDING_SLOTS {
			text_button_draw(r, &p.keys[button][slot])
		}
	}
	text_button_draw(r, &p.reset)

	for o in Option {
		menu_draw_text(r, OPTION_NAMES[o], PREFS_LABEL_X, i32(option_y(o)) + 5, white)
		text_button_draw(r, &p.toggle[o])
		if o == .Sound || o == .Music {
			text_button_draw(r, &p.volume_down[o])
			text_button_draw(r, &p.volume_up[o])
		}
	}
	text_button_draw(r, &p.back)

	status: string
	switch {
	case p.capturing:
		status = fmt.tprintf("PLAYER %d %s: PRESS A KEY -- BACKSPACE CLEARS, ESC CANCELS",
			p.player + 1, BUTTON_NAMES[p.capture_button])
	case p.player == 1:
		status = "PLAYER 2'S KEYS ARE USED IN LOCAL 2 PLAYER GAMES -- ESC ALWAYS PAUSES"
	case:
		status = "PLAYER 1'S KEYS ARE ALSO YOURS IN NETPLAY -- ESC ALWAYS PAUSES"
	}
	menu_draw_text(r, status, SCREEN_W / 2, PREFS_STATUS_Y, dim, .Centre)
}
