package prefs

// Where the game and the editor keep what a player or an author saves:
// progress, high scores, preferences, the editor's brush profiles and
// imported models.

import "core:os"
import "core:strings"

// $XDG_DATA_HOME/deimos-rising/<name>, else %APPDATA%\deimos-rising\<name>
// on Windows (which has no HOME), else ~/.local/share/deimos-rising/<name>.
// Empty when none of those is set: callers treat that as "no persistence"
// rather than failing. Shared by progress, high scores, preferences and the editor.
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
