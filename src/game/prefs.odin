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

// $XDG_DATA_HOME/deimos-rising/<name>, else %APPDATA%\deimos-rising\<name>
// on Windows (which has no HOME), else ~/.local/share/deimos-rising/<name>.
// Empty when none of those is set: callers treat that as "no persistence"
// rather than failing. Shared by progress, high scores and preferences.
user_data_path :: proc(name: string, allocator := context.allocator) -> string {
	if dir := os.get_env("XDG_DATA_HOME", allocator); dir != "" {
		return strings.concatenate({dir, "/deimos-rising/", name}, allocator)
	}
	when ODIN_OS == .Windows {
		if dir := os.get_env("APPDATA", allocator); dir != "" {
			return strings.concatenate({dir, "/deimos-rising/", name}, allocator)
		}
	}
	home := os.get_env("HOME", allocator)
	if home == "" {
		return ""
	}
	return strings.concatenate({home, "/.local/share/deimos-rising/", name}, allocator)
}

// Best-effort, like progress_save: a read-only data directory means changes
// last only for this run.
user_data_write :: proc(name: string, contents: string) {
	path := user_data_path(name, context.temp_allocator)
	if path == "" {
		return
	}
	os.make_directory_all(path[:strings.last_index(path, "/")])
	_ = os.write_entire_file(path, transmute([]byte)contents)
}

// What was saved, plus this run's launch flags. A flag (-classic,
// -diagnostics, -fullscreen, -highrefreshrate) switches its setting on for the run without
// saving it; changing that setting in Preferences then drops the flag and
// saves the new value, so the menu always shows and controls what is live.
Prefs_State :: struct {
	saved:  prefs.Prefs,
	launch: Settings,
}

prefs_state_load :: proc(launch: Settings) -> Prefs_State {
	ps := Prefs_State{saved = prefs.defaults(), launch = launch}
	path := user_data_path("preferences", context.temp_allocator)
	if path == "" {
		return ps
	}
	if bytes, err := os.read_entire_file(path, context.temp_allocator); err == nil {
		ps.saved = prefs.parse(string(bytes))
	}
	return ps
}

prefs_state_save :: proc(ps: ^Prefs_State) {
	user_data_write("preferences", prefs.format(&ps.saved, context.temp_allocator))
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


// Presentation-side input capture: the simulation never reads a device.
// Every button is read as held; the sim does its own edge detection (e.g.
// weapons_process's `switch_ && !h.prev_switch` for Change_Air), so reading
// Change_Air as a one-frame IsKeyPressed, as this once did, could only lose
// a press that landed on a render frame with no sim step in it.
gather_input :: proc(b: ^prefs.Bindings) -> sim.Buttons {
	out: sim.Buttons
	for keys, action in b {
		for k in keys {
			if k != prefs.KEY_NONE && rl.IsKeyDown(rl.KeyboardKey(k)) {
				out += {sim.Button(action)}
			}
		}
	}
	return out
}

// Whether any key bound to `action` went down this frame.
binding_pressed :: proc(b: ^prefs.Bindings, action: prefs.Action) -> bool {
	for k in b[action] {
		if k != prefs.KEY_NONE && rl.IsKeyPressed(rl.KeyboardKey(k)) {
			return true
		}
	}
	return false
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
