package game

// The game side of dr:prefs: where the file lives, how launch flags combine
// with what was saved, and turning bindings into sim.Buttons.

import "core:fmt"
import "core:os"
import "core:strings"

import rl "vendor:raylib"

import "dr:prefs"
import "dr:sim"

// dr:prefs holds key codes as plain i32 to stay raylib-free; these make a
// mismatch with raylib's own values a build failure.
#assert(i32(rl.KeyboardKey.SPACE) == prefs.KEY_SPACE)
#assert(i32(rl.KeyboardKey.A) == prefs.KEY_A)
#assert(i32(rl.KeyboardKey.W) == prefs.KEY_W)
#assert(i32(rl.KeyboardKey.RIGHT) == prefs.KEY_RIGHT)
#assert(i32(rl.KeyboardKey.LEFT) == prefs.KEY_LEFT)
#assert(i32(rl.KeyboardKey.DOWN) == prefs.KEY_DOWN)
#assert(i32(rl.KeyboardKey.UP) == prefs.KEY_UP)
#assert(i32(rl.KeyboardKey.LEFT_SHIFT) == prefs.KEY_LEFT_SHIFT)
#assert(i32(rl.KeyboardKey.LEFT_CONTROL) == prefs.KEY_LEFT_CONTROL)
#assert(i32(rl.KeyboardKey.KEY_NULL) == prefs.KEY_NONE)
#assert(i32(rl.KeyboardKey.CAPS_LOCK) == prefs.KEY_CAPS_LOCK)
#assert(i32(rl.KeyboardKey.ESCAPE) == prefs.KEY_ESCAPE)

// What was saved, plus this run's launch flags. A flag (-classic,
// -diagnostics, -fullscreen, or a plugin's launch switch) switches its
// setting on for the run without saving it; changing that setting in
// Preferences then drops the flag and saves the new value, so the menu
// always shows and controls what is live.
Prefs_State :: struct {
	saved:       prefs.Prefs,
	launch:      Settings,
	launch_mods: sim.Mods, // what the plugins' launch switches turned on
}

prefs_state_load :: proc(launch: Settings) -> Prefs_State {
	ps := Prefs_State{saved = prefs.defaults(), launch = launch, launch_mods = prefs.launch_mods(launch.args)}
	path := prefs.user_data_path("preferences", context.temp_allocator)
	if path == "" {
		return ps
	}
	if bytes, err := os.read_entire_file(path, context.temp_allocator); err == nil {
		ps.saved = prefs.parse(string(bytes))
	}
	return ps
}

prefs_state_save :: proc(ps: ^Prefs_State) {
	prefs.user_data_write("preferences", prefs.format(&ps.saved, context.temp_allocator))
}

prefs_classic :: proc(ps: ^Prefs_State) -> bool {return ps.saved.classic || ps.launch.classic}
prefs_diagnostics :: proc(ps: ^Prefs_State) -> bool {return ps.saved.diagnostics || ps.launch.diagnostics}
prefs_fullscreen :: proc(ps: ^Prefs_State) -> bool {return ps.saved.fullscreen || ps.launch.fullscreen}

prefs_set_classic :: proc(ps: ^Prefs_State, on: bool) {
	ps.saved.classic, ps.launch.classic = on, false
	prefs_state_save(ps)
}

prefs_set_diagnostics :: proc(ps: ^Prefs_State, on: bool) {
	ps.saved.diagnostics, ps.launch.diagnostics = on, false
	prefs_state_save(ps)
}

prefs_set_fullscreen :: proc(ps: ^Prefs_State, on: bool) {
	ps.saved.fullscreen, ps.launch.fullscreen = on, false
	prefs_state_save(ps)
}


// The stick deflection that counts as a push, 0..1.
PAD_DEADZONE :: 0.5

// The connected controllers' system ids, in order.
pads_connected :: proc(allocator := context.temp_allocator) -> []i32 {
	out := make([dynamic]i32, 0, 4, allocator)
	for id in 0 ..< i32(16) {
		if rl.IsGamepadAvailable(id) {
			append(&out, id)
		}
	}
	return out[:]
}

pad_name_of :: proc(id: i32) -> string {
	return string(rl.GetGamepadName(id))
}

// The controller `player` has chosen, if it is connected: the one with the
// saved name at the saved place, else the first with the name; with no name
// saved, the one at the player's own place, else the first.
pad_of :: proc(ps: ^Prefs_State, player: int) -> (id: i32, ok: bool) {
	saved := ps.saved
	name := prefs.pad_name_string(&saved.pad_name[player])
	connected := pads_connected()
	if name == "" {
		for c in connected {
			if int(c) == player {
				return c, true
			}
		}
		return len(connected) > 0 ? connected[0] : 0, len(connected) > 0
	}
	for c in connected {
		if c == saved.pad_index[player] && pad_name_of(c) == name {
			return c, true
		}
	}
	for c in connected {
		if pad_name_of(c) == name {
			return c, true
		}
	}
	return
}

// Whether controller binding `code` of pad `id` is held.
pad_code_down :: proc(id: i32, code: i32) -> bool {
	if code == prefs.PAD_NONE {
		return false
	}
	if axis, positive, is_axis := prefs.pad_axis_of(code); is_axis {
		v := rl.GetGamepadAxisMovement(id, rl.GamepadAxis(axis))
		return positive ? v > PAD_DEADZONE : v < -PAD_DEADZONE
	}
	return rl.IsGamepadButtonDown(id, rl.GamepadButton(code))
}

// Presentation-side input capture: the simulation never reads a device.
// Every button is read as held; the sim does its own edge detection (e.g.
// weapons_process's `switch_ && !h.prev_switch` for Change_Air), so reading
// Change_Air as a one-frame IsKeyPressed, as this once did, could only lose
// a press that landed on a render frame with no sim step in it. The keys or
// the controller, as `player` chose in Preferences.
gather_input :: proc(ps: ^Prefs_State, player: int) -> sim.Buttons {
	out: sim.Buttons
	if ps.saved.input[player] == .Controller {
		id, ok := pad_of(ps, player)
		if !ok {
			return out
		}
		for codes, action in ps.saved.pad_bindings[player] {
			for c in codes {
				if pad_code_down(id, c) {
					out += {sim.Button(action)}
				}
			}
		}
		return out
	}
	for keys, action in ps.saved.bindings[player] {
		for k in keys {
			if k != prefs.KEY_NONE && rl.IsKeyDown(rl.KeyboardKey(k)) {
				out += {sim.Button(action)}
			}
		}
	}
	return out
}

// Whether `player`'s `action` went down this frame. Pause answers to the
// keyboard's binding too, whatever the player drives with, so Escape always
// pauses a game played on a controller.
binding_pressed :: proc(ps: ^Prefs_State, player: int, action: prefs.Action) -> bool {
	pressed := false
	if ps.saved.input[player] == .Controller {
		if id, ok := pad_of(ps, player); ok {
			for c, slot in ps.saved.pad_bindings[player][action] {
				down := pad_code_down(id, c)
				if down && !shared.axis_was[player][action][slot] && (c >= prefs.PAD_AXIS || rl.IsGamepadButtonPressed(id, rl.GamepadButton(c))) {
					pressed = true
				}
				shared.axis_was[player][action][slot] = down
			}
		}
		if action != .Pause {
			return pressed
		}
	}
	for k in ps.saved.bindings[player][action] {
		if k != prefs.KEY_NONE && rl.IsKeyPressed(rl.KeyboardKey(k)) {
			pressed = true
		}
	}
	return pressed
}

// A short, upper-case name for controller binding `code`.
pad_code_name :: proc(code: i32) -> string {
	if code == prefs.PAD_NONE {
		return "--"
	}
	if axis, positive, ok := prefs.pad_axis_of(code); ok {
		names := [6]string{"LEFT STICK", "LEFT STICK", "RIGHT STICK", "RIGHT STICK", "LEFT TRIGGER", "RIGHT TRIGGER"}
		dirs := [6][2]string{{"LEFT", "RIGHT"}, {"UP", "DOWN"}, {"LEFT", "RIGHT"}, {"UP", "DOWN"}, {"", ""}, {"", ""}}
		if axis >= 0 && axis < 6 {
			return strings.trim_space(fmt.tprintf("%s %s", names[axis], dirs[axis][positive ? 1 : 0]))
		}
		return fmt.tprintf("AXIS %d", axis)
	}
	#partial switch rl.GamepadButton(code) {
	case .LEFT_FACE_UP:
		return "DPAD UP"
	case .LEFT_FACE_RIGHT:
		return "DPAD RIGHT"
	case .LEFT_FACE_DOWN:
		return "DPAD DOWN"
	case .LEFT_FACE_LEFT:
		return "DPAD LEFT"
	case .RIGHT_FACE_UP:
		return "BUTTON Y"
	case .RIGHT_FACE_RIGHT:
		return "BUTTON B"
	case .RIGHT_FACE_DOWN:
		return "BUTTON A"
	case .RIGHT_FACE_LEFT:
		return "BUTTON X"
	case .LEFT_TRIGGER_1:
		return "LEFT BUMPER"
	case .LEFT_TRIGGER_2:
		return "LEFT TRIGGER"
	case .RIGHT_TRIGGER_1:
		return "RIGHT BUMPER"
	case .RIGHT_TRIGGER_2:
		return "RIGHT TRIGGER"
	case .MIDDLE_LEFT:
		return "BACK"
	case .MIDDLE:
		return "GUIDE"
	case .MIDDLE_RIGHT:
		return "START"
	case .LEFT_THUMB:
		return "LEFT STICK PRESS"
	case .RIGHT_THUMB:
		return "RIGHT STICK PRESS"
	}
	return fmt.tprintf("PAD %d", code)
}

// A short, upper-case name for a key, for the Preferences screen.
key_name :: proc(k: i32) -> string {
	if k == prefs.KEY_NONE {
		return "--"
	}
	key := rl.KeyboardKey(k)
	#partial switch key {
	case .LEFT_CONTROL:
		return "LEFT CTRL"
	case .RIGHT_CONTROL:
		return "RIGHT CTRL"
	case .APOSTROPHE:
		return "'"
	case .COMMA:
		return ","
	case .MINUS:
		return "-"
	case .PERIOD:
		return "."
	case .SLASH:
		return "/"
	case .SEMICOLON:
		return ";"
	case .EQUAL:
		return "="
	case .LEFT_BRACKET:
		return "["
	case .BACKSLASH:
		return "\\"
	case .RIGHT_BRACKET:
		return "]"
	case .GRAVE:
		return "`"
	}
	name := fmt.tprint(key)
	if name == "" || name[0] == '%' || strings.has_prefix(name, "KeyboardKey") {
		return fmt.tprintf("KEY %d", k) // not a named raylib key
	}
	name, _ = strings.replace_all(name, "KP_", "NUM ", context.temp_allocator)
	name, _ = strings.replace_all(name, "_", " ", context.temp_allocator)
	return name
}
