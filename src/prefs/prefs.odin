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
KEY_CAPS_LOCK :: 280
KEY_ESCAPE :: 256

// The controls a player can bind: the original's seven, then Pause, in
// sim.Button's order so each converts with a cast.
//
// Pause defaults to Escape. The original paused on Caps Lock (DirectInput
// key 0x3a), but raylib cannot read Caps Lock as a key. Its GLFW key
// callback (KeyCallback in the linked libraylib.a 6.0: `cmp $0x118` then
// `and $0x10` on the mods) forces KEY_CAPS_LOCK down whenever the lock
// modifier is on. The key then reads as the lock state, not the key: a
// press shows only when the lock turns on, so every other tap is lost and
// a pause could not be undone. Binding Caps Lock is still allowed, with
// that flaw.
Action :: enum u8 {
	Up,
	Down,
	Left,
	Right,
	Fire_Air,
	Fire_Ground,
	Change_Air,
	Pause,
}
#assert(int(Action.Up) == int(sim.Button.Up))
#assert(int(Action.Down) == int(sim.Button.Down))
#assert(int(Action.Left) == int(sim.Button.Left))
#assert(int(Action.Right) == int(sim.Button.Right))
#assert(int(Action.Fire_Air) == int(sim.Button.Fire_Air))
#assert(int(Action.Fire_Ground) == int(sim.Button.Fire_Ground))
#assert(int(Action.Change_Air) == int(sim.Button.Change_Air))
#assert(int(Action.Pause) == int(sim.Button.Pause))

// Two keys per action: player 1 has always had both the arrows and WASD.
BINDING_SLOTS :: 2
Bindings :: [Action][BINDING_SLOTS]i32

VOLUME_STEP :: 10 // percent per click of the volume arrows

Prefs :: struct {
	bindings:     [sim.MAX_PLAYERS]Bindings,
	sfx_volume:   int, // percent, 0..100
	music_volume: int, // percent, 0..100
	fullscreen:   bool,
	diagnostics:  bool,
	classic:      bool,
	// The name last entered in the netplay lobby, offered again next time
	// and recorded against this player's high scores after a netplay game.
	netplay_name: Name,
	// Enhancements beyond the original, each off in classic mode
	// (game/extras.odin). One value per entry of EXTRAS.
	extras: [Extra]int,
}

// Extras: every setting for a feature the original did not have. Adding
// one means an entry here and in EXTRAS, and using it through game/
// extras.odin's extra_on/extra_value -- saving, loading and its row on the
// Preferences Extras page all come from this table. Classic mode switches
// every one of them off, so classic stays the original game.
Extra :: enum {
	High_Refresh_Rate, // draw at the monitor's rate, interpolating between the fixed 30 Hz steps
	Accent_Colours,    // the two hues below, on or off together
	Accent_Hue,        // player 1's colour, and yours in netplay: ship trim, crosshair and air-to-ground shots
	Accent_Hue_P2,     // player 2's colour in a local game
	Self_Outline,      // an outline in your accent round your own ship
	Easy_Mode,         // a passive upgrade to choose after every level (sim/passives.odin); also on level select and the lobby
}

Extra_Kind :: enum {
	Toggle, // 0 or 1
	Hue,    // degrees, 0..359
}

Extra_Info :: struct {
	key:     string, // in the save file; high_refresh_rate and accent_hue predate the table
	label:   string,
	kind:    Extra_Kind,
	default: int,
}

EXTRAS := [Extra]Extra_Info {
	.High_Refresh_Rate = {"high_refresh_rate", "HIGH REFRESH RATE", .Toggle, 0},
	.Accent_Colours    = {"accent_colours", "ACCENT COLOURS", .Toggle, 1},
	.Accent_Hue        = {"accent_hue", "P1 ACCENT HUE", .Hue, 190}, // the cyan of the original crosshair
	.Accent_Hue_P2     = {"accent_hue_p2", "P2 ACCENT HUE", .Hue, 63}, // player 2's own gold (game/render.odin TRIM_SATURATION)
	.Self_Outline      = {"self_outline", "SELF OUTLINE", .Toggle, 0},
	.Easy_Mode         = {"easy_mode", "EASY MODE", .Toggle, 0},
}

// Clamps or wraps a value to what its kind allows.
extra_clean :: proc(e: Extra, v: int) -> int {
	switch EXTRAS[e].kind {
	case .Toggle:
		return v != 0 ? 1 : 0
	case .Hue:
		return hue_wrap(v)
	}
	return v
}

// A player's name, the same 20 printable-ASCII characters the high score
// name entry allows (game/menu_high_score_entry.odin, from the original's
// 0x14-byte buffer). Fixed-size so Prefs stays a plain value.
NAME_MAX :: 20

Name :: struct {
	buf: [NAME_MAX]u8,
	len: int,
}

name_string :: proc(n: ^Name) -> string {
	return string(n.buf[:n.len])
}

// Keeps printable ASCII only, drops surrounding spaces, and cuts anything
// past NAME_MAX.
name_set :: proc(n: ^Name, text: string) {
	// Built aside and assigned last: `text` may be a slice of `n` itself
	// (name_string), which clearing `n` first would wipe.
	out: Name
	trimmed := strings.trim_space(text)
	for i in 0 ..< len(trimmed) {
		if c := trimmed[i]; c >= 0x20 && c <= 0x7e && out.len < NAME_MAX {
			out.buf[out.len] = c
			out.len += 1
		}
	}
	for out.len > 0 && out.buf[out.len - 1] == ' ' {
		out.len -= 1 // a cut can end on a space
		out.buf[out.len] = 0 // so two equal names compare equal
	}
	n^ = out
}

extra_by_key :: proc(key: string) -> (Extra, bool) {
	for info, e in EXTRAS {
		if info.key == key {
			return e, true
		}
	}
	return {}, false
}

// Any whole number of degrees, brought into 0..359.
hue_wrap :: proc(h: int) -> int {
	return ((h % 360) + 360) % 360
}

// Player 1's defaults are exactly the controls hard-coded before bindings
// existed (game/main.odin's old gather_input), so an existing player finds
// nothing moved. Player 2 had no keys at all -- local co-op fed it an empty
// input every step -- so theirs are new: IJKL on the right of the keyboard,
// clear of player 1's arrows/WASD/Space/Ctrl/Shift, with U/O and ; beside
// them.
defaults :: proc() -> Prefs {
	p := Prefs {
		sfx_volume   = 100,
		music_volume = 100,
	}
	for info, e in EXTRAS {
		p.extras[e] = info.default
	}
	p.bindings[0] = {
		.Up          = {KEY_UP, KEY_W},
		.Down        = {KEY_DOWN, KEY_S},
		.Left        = {KEY_LEFT, KEY_A},
		.Right       = {KEY_RIGHT, KEY_D},
		.Fire_Air    = {KEY_SPACE, KEY_NONE},
		.Fire_Ground = {KEY_LEFT_CONTROL, KEY_NONE},
		.Change_Air  = {KEY_LEFT_SHIFT, KEY_NONE},
		.Pause       = {KEY_ESCAPE, KEY_NONE}, // see Action
	}
	p.bindings[1] = {
		.Up          = {KEY_I, KEY_NONE},
		.Down        = {KEY_K, KEY_NONE},
		.Left        = {KEY_J, KEY_NONE},
		.Right       = {KEY_L, KEY_NONE},
		.Fire_Air    = {KEY_U, KEY_NONE},
		.Fire_Ground = {KEY_O, KEY_NONE},
		.Change_Air  = {KEY_SEMICOLON, KEY_NONE},
		.Pause       = {KEY_NONE, KEY_NONE}, // the original has one pause key, player 1's
	}
	return p
}

// Binds `key` to one slot, first taking it off anything else it was bound
// to, for either player: one key driving two actions (or both ships in
// co-op) is never what a player rebinding meant. KEY_NONE just clears.
bind :: proc(p: ^Prefs, player: int, button: Action, slot: int, key: i32) {
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
// an Action does not silently drop everyone's bindings. Pause is saved as
// "pause_key": a "pause" line is from when P was the default, and every save
// wrote it out, so honouring it would keep everyone off the default. It is
// ignored.
@(private = "file")
BUTTON_KEYS := [Action]string {
	.Up          = "up",
	.Down        = "down",
	.Left        = "left",
	.Right       = "right",
	.Fire_Air    = "fire_air",
	.Fire_Ground = "fire_ground",
	.Change_Air  = "change_weapon",
	.Pause       = "pause_key",
}

// One `name=value` per line, like progress.odin's and highscores.odin's
// plain-text saves. Bindings are `p<N>.<action>=<key>,<key>`.
format :: proc(p: ^Prefs, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	fmt.sbprintf(&sb, "sfx_volume=%d\n", p.sfx_volume)
	fmt.sbprintf(&sb, "music_volume=%d\n", p.music_volume)
	fmt.sbprintf(&sb, "fullscreen=%d\n", p.fullscreen ? 1 : 0)
	fmt.sbprintf(&sb, "diagnostics=%d\n", p.diagnostics ? 1 : 0)
	fmt.sbprintf(&sb, "classic=%d\n", p.classic ? 1 : 0)
	fmt.sbprintf(&sb, "netplay_name=%s\n", name_string(&p.netplay_name))
	for info, e in EXTRAS {
		fmt.sbprintf(&sb, "%s=%d\n", info.key, p.extras[e])
	}
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
// A default can collide with a key the file already uses: an older file can
// have bound a key that a later version made a default. What the player
// chose wins; the default gives way, so one key never ends up doing two
// things.
parse :: proc(text: string) -> Prefs {
	p := defaults()
	from_file: [sim.MAX_PLAYERS]bit_set[Action]
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
		case "diagnostics":
			parse_flag(value, &p.diagnostics)
		case "classic":
			parse_flag(value, &p.classic)
		case "netplay_name":
			name_set(&p.netplay_name, value)
		case:
			if e, ok := extra_by_key(name); ok {
				if v, vok := strconv.parse_int(value); vok {
					p.extras[e] = extra_clean(e, v)
				}
				continue
			}
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
parse_binding :: proc(name, value: string, p: ^Prefs) -> (player: int, button: Action, ok: bool) {
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
drop_colliding_defaults :: proc(p: ^Prefs, from_file: [sim.MAX_PLAYERS]bit_set[Action]) {
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
