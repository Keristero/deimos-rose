package game

// Phase 7 stage 2: persists "highest level reached" across runs -- the
// original's U_Prefs slot 3, backed by the Win32 registry. Research against
// the decompiled corpus (FUN_00426d80.c, the post-session update, and
// Priv_Preview/FUN_0042b4e0.c, the Level Select gate that reads it back)
// confirmed this is one *global* counter, shared across Single and Co-Op and
// monotonically increased -- never tracked per sim.Game_Type. See
// docs/phase-7-faithful-menus.md.
//
// This is the first piece of persistent state this reimplementation writes:
// grepping the whole tree for existing save/prefs/progress handling turned up
// nothing to follow, so this picks the ordinary XDG data location a Linux
// game would use rather than inventing a project-specific convention.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// $XDG_DATA_HOME/deimos-rising/progress, or ~/.local/share/deimos-rising/progress
// when XDG_DATA_HOME is unset (the common case). Empty when neither
// XDG_DATA_HOME nor HOME is set -- headless captures (tools/oracle/) run
// inside a podman container with HOME=/w, so this only turns up empty under a
// more stripped-down environment than that; progress_load/save treat it as
// "no persistence available" rather than failing.
@(private = "file")
progress_path :: proc(allocator := context.allocator) -> string {
	if dir := os.get_env("XDG_DATA_HOME", allocator); dir != "" {
		return strings.concatenate({dir, "/deimos-rising/progress"}, allocator)
	}
	home := os.get_env("HOME", allocator)
	if home == "" {
		return ""
	}
	return strings.concatenate({home, "/.local/share/deimos-rising/progress"}, allocator)
}

// The highest 1-based level-list position unlocked so far, or 1 (only the
// first level) if no save exists yet -- the same starting point as a fresh
// install, matching a fresh U_Prefs slot 3.
progress_load :: proc() -> int {
	path := progress_path(context.temp_allocator)
	if path == "" {
		return 1
	}
	bytes, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return 1
	}
	n, ok := strconv.parse_int(strings.trim_space(string(bytes)))
	if !ok || n < 1 {
		return 1
	}
	return n
}

// Called from flow.odin whenever fl.highest_reached advances. Best-effort: a
// read-only home directory or progress_path returning "" just means progress
// doesn't persist past this run, not a crash -- there is nothing the player
// can do about either from inside the game.
progress_save :: proc(highest: int) {
	path := progress_path(context.temp_allocator)
	if path == "" {
		return
	}
	dir := path[:strings.last_index(path, "/")]
	os.make_directory_all(dir)
	_ = os.write_entire_file(path, transmute([]byte)fmt.tprintf("%d", highest))
}
