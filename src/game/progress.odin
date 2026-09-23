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

// Saved as user_data_path("progress") (game/prefs.odin): the ordinary XDG
// data location on Linux, %APPDATA% on Windows. Empty when no such directory
// is known -- headless captures (tools/oracle/) run inside a podman
// container with HOME=/w, so this only turns up empty under a more
// stripped-down environment than that; progress_load/save treat it as "no
// persistence available" rather than failing.
// The highest 1-based level-list position unlocked so far, or 1 (only the
// first level) if no save exists yet -- the same starting point as a fresh
// install, matching a fresh U_Prefs slot 3.
progress_load :: proc() -> int {
	path := user_data_path("progress", context.temp_allocator)
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
// read-only data directory or user_data_path returning "" just means progress
// doesn't persist past this run, not a crash -- there is nothing the player
// can do about either from inside the game.
progress_save :: proc(highest: int) {
	user_data_write("progress", fmt.tprintf("%d", highest))
}
