package prefs

// The player's preferences: key bindings for each local player, sound and
// music volume, and the display/diagnostics/classic switches. New content --
// the original's Preferences was a native Win32 dialog with no art to port
// (game/menu_main.odin) -- so nothing here is traced from the binary.
//
// Kept apart from game/ and free of raylib so tests can cover the save
// format and the rebinding rules without a window. Key codes are raylib's
// KeyboardKey values (themselves GLFW's) held as plain i32; game/prefs.odin
// #asserts the constants below against rl.KeyboardKey, so a mismatch fails
// the build rather than binding the wrong keys.

import "core:fmt"
import "core:strconv"
import "core:strings"

import "dr:sim"

KEY_NONE :: 0
KEY_SPACE :: 32
KEY_A :: 65
KEY_D :: 68
KEY_I :: 73
KEY_J :: 74
KEY_K :: 75
KEY_L :: 76
KEY_SEMICOLON :: 59
KEY_O :: 79
KEY_P :: 80
KEY_S :: 83
KEY_U :: 85
KEY_W :: 87
KEY_RIGHT :: 262
KEY_LEFT :: 263
KEY_DOWN :: 264
KEY_UP :: 265
KEY_LEFT_SHIFT :: 340
KEY_LEFT_CONTROL :: 341

// Two keys per action: player 1 has always had both the arrows and WASD.
// Pause is an action like the rest; Escape also always pauses, for every
// player, and cannot be bound -- it has to stay free to cancel a rebind.
BINDING_SLOTS :: 2
Bindings :: [sim.Button][BINDING_SLOTS]i32

VOLUME_STEP :: 10 // percent per click of the volume arrows

Prefs :: struct {
	bindings:     [sim.MAX_PLAYERS]Bindings,
	sfx_volume:   int, // percent, 0..100
	music_volume: int, // percent, 0..100
	fullscreen:   bool,
	// Draw at the monitor's refresh rate, interpolating between sim steps
	// (game/render.odin). The simulation still steps at a fixed 30 Hz.
	high_refresh_rate: bool,
	diagnostics:  bool,
	classic:      bool,
}

// Player 1's defaults are exactly the controls hard-coded before bindings
// existed (game/main.odin's old gather_input), so an existing player finds
// nothing moved. Player 2 had no keys at all -- local co-op fed it an empty
// input every step -- so theirs are new: IJKL on the right of the keyboard,
// clear of player 1's arrows/WASD/Space/Ctrl/Shift, with U/O and ; beside
// them. P is player 1's Pause, as it was before Pause could be rebound;
// player 2 has none by default (Escape pauses for both).
defaults :: proc() -> Prefs {
	p := Prefs {
		sfx_volume   = 100,
		music_volume = 100,
	}
	p.bindings[0] = {
		.Up          = {KEY_UP, KEY_W},
		.Down        = {KEY_DOWN, KEY_S},
		.Left        = {KEY_LEFT, KEY_A},
		.Right       = {KEY_RIGHT, KEY_D},
		.Fire_Air    = {KEY_SPACE, KEY_NONE},
		.Fire_Ground = {KEY_LEFT_CONTROL, KEY_NONE},
		.Change_Air  = {KEY_LEFT_SHIFT, KEY_NONE},
		.Pause       = {KEY_P, KEY_NONE},
	}
	p.bindings[1] = {
		.Up          = {KEY_I, KEY_NONE},
		.Down        = {KEY_K, KEY_NONE},
		.Left        = {KEY_J, KEY_NONE},
		.Right       = {KEY_L, KEY_NONE},
		.Fire_Air    = {KEY_U, KEY_NONE},
		.Fire_Ground = {KEY_O, KEY_NONE},
		.Change_Air  = {KEY_SEMICOLON, KEY_NONE},
		.Pause       = {KEY_NONE, KEY_NONE},
	}
	return p
}

// Binds `key` to one slot, first taking it off anything else it was bound
// to, for either player: one key driving two actions (or both ships in
// co-op) is never what a player rebinding meant. KEY_NONE just clears.
bind :: proc(p: ^Prefs, player: int, button: sim.Button, slot: int, key: i32) {
	if key != KEY_NONE {
		for &b in p.bindings {
			for &keys in b {
				for &k in keys {
					if k == key {
						k = KEY_NONE
					}
				}
			}
		}
	}
	p.bindings[player][button][slot] = key
}

step_volume :: proc(v: ^int, dir: int) {
	v^ = clamp(v^ + dir * VOLUME_STEP, 0, 100)
}

// Stable names for the save file -- not the enum's own spelling, so renaming
// a sim.Button does not silently drop everyone's bindings.
@(private = "file")
BUTTON_KEYS := [sim.Button]string {
	.Up          = "up",
	.Down        = "down",
	.Left        = "left",
	.Right       = "right",
	.Fire_Air    = "fire_air",
	.Fire_Ground = "fire_ground",
	.Change_Air  = "change_weapon",
	.Pause       = "pause",
}

// One `name=value` per line, like progress.odin's and highscores.odin's
// plain-text saves. Bindings are `p<N>.<action>=<key>,<key>`.
format :: proc(p: ^Prefs, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	fmt.sbprintf(&sb, "sfx_volume=%d\n", p.sfx_volume)
	fmt.sbprintf(&sb, "music_volume=%d\n", p.music_volume)
	fmt.sbprintf(&sb, "fullscreen=%d\n", p.fullscreen ? 1 : 0)
	fmt.sbprintf(&sb, "high_refresh_rate=%d\n", p.high_refresh_rate ? 1 : 0)
	fmt.sbprintf(&sb, "diagnostics=%d\n", p.diagnostics ? 1 : 0)
	fmt.sbprintf(&sb, "classic=%d\n", p.classic ? 1 : 0)
	for b, player in p.bindings {
		for keys, button in b {
			fmt.sbprintf(&sb, "p%d.%s=%d,%d\n", player + 1, BUTTON_KEYS[button], keys[0], keys[1])
		}
	}
	return strings.to_string(sb)
}

// Starts from defaults() and applies whatever lines it understands, so a
// missing file, an older file without some setting, or a hand-edited typo
// each fall back per setting rather than losing the lot.
//
// A default can collide with a key the file already uses: a file from
// before Pause was bindable has player 2's Change Weapon on P, which is now
// player 1's default Pause. What the player chose wins; the default gives
// way, so one key never ends up doing two things.
parse :: proc(text: string) -> Prefs {
	p := defaults()
	from_file: [sim.MAX_PLAYERS]sim.Buttons
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		eq := strings.index_byte(line, '=')
		if eq < 0 {
			continue
		}
		name := strings.trim_space(line[:eq])
		value := strings.trim_space(line[eq + 1:])
		switch name {
		case "sfx_volume":
			parse_volume(value, &p.sfx_volume)
		case "music_volume":
			parse_volume(value, &p.music_volume)
		case "fullscreen":
			parse_flag(value, &p.fullscreen)
		case "high_refresh_rate":
			parse_flag(value, &p.high_refresh_rate)
		case "diagnostics":
			parse_flag(value, &p.diagnostics)
		case "classic":
			parse_flag(value, &p.classic)
		case:
			if player, button, ok := parse_binding(name, value, &p); ok {
				from_file[player] += {button}
			}
		}
	}
	drop_colliding_defaults(&p, from_file)
	return p
}

@(private = "file")
parse_volume :: proc(value: string, out: ^int) {
	if v, ok := strconv.parse_int(value); ok {
		out^ = clamp(v, 0, 100)
	}
}

@(private = "file")
parse_flag :: proc(value: string, out: ^bool) {
	switch value {
	case "1":
		out^ = true
	case "0":
		out^ = false
	}
}

@(private = "file")
parse_binding :: proc(name, value: string, p: ^Prefs) -> (player: int, button: sim.Button, ok: bool) {
	if len(name) < 4 || name[0] != 'p' || name[2] != '.' {
		return
	}
	player = int(name[1] - '1')
	if player < 0 || player >= sim.MAX_PLAYERS {
		return
	}
	found := false
	for key, b in BUTTON_KEYS {
		if key == name[3:] {
			button, found = b, true
		}
	}
	comma := strings.index_byte(value, ',')
	if !found || comma < 0 {
		return
	}
	k0, ok0 := strconv.parse_int(value[:comma])
	k1, ok1 := strconv.parse_int(value[comma + 1:])
	if !ok0 || !ok1 {
		return
	}
	p.bindings[player][button] = {i32(k0), i32(k1)}
	return player, button, true
}

@(private = "file")
drop_colliding_defaults :: proc(p: ^Prefs, from_file: [sim.MAX_PLAYERS]sim.Buttons) {
	chosen: map[i32]bool
	defer delete(chosen)
	for b, player in p.bindings {
		for keys, button in b {
			if button in from_file[player] {
				for k in keys {
					chosen[k] = true
				}
			}
		}
	}
	for &b, player in p.bindings {
		for &keys, button in b {
			if button in from_file[player] {
				continue
			}
			for &k in keys {
				if k != KEY_NONE && chosen[k] {
					k = KEY_NONE
				}
			}
		}
	}
}
