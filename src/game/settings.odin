package game

import "core:strconv"

// Command-line switches for how the game presents itself, as opposed to what
// the simulation does -- the simulation takes no settings at all. See
// notes/user-guidance-mid-phase5.md and docs/decisions.md D16/D17.
Settings :: struct {
	// -classic: prefer matching the original's look exactly over a nicer
	// alternative, wherever the two are ever in tension. Off by default: a
	// choice that makes the game look better without changing what it does
	// is worth keeping (D16). Today it hides the main menu's Netplay item
	// (D21, D30).
	//
	// -classic, -diagnostics and -fullscreen each switch their setting on
	// for one run; Preferences shows and changes the same settings, and
	// saves them (game/prefs.odin's Prefs_State).
	classic: bool,
	// -highrefreshrate: present at the monitor's native refresh rate instead
	// of the original's fixed 30 FPS, drawing each frame interpolated
	// between the last two sim steps (D33). The simulation still steps at a
	// fixed 30 Hz regardless (D17). Also in Preferences.
	high_refresh_rate: bool,
	// -diagnostics: a small rolling-stats overlay in the bottom-right corner
	// (game/diagnostics.odin) -- FPS always, plus (in a netplay session)
	// ping, rollbacks/sec and updates/sec. New content, no original
	// equivalent -- notes/netcode-enhancements.md asked for it.
	diagnostics: bool,
	// -fullscreen: start in a borderless window covering the monitor, the
	// game scaled to fit (main.odin's canvas). Also in Preferences.
	fullscreen: bool,
	// -campaign <plugin>, -level <identifier> and -row <n>: play a level
	// straight away, from map row n (level_start_at_row), for testing one
	// (D54). -campaign names a campaign plugin, which is on for the run;
	// alone it only picks the campaign Level Select shows. -level takes an
	// identifier ("Lucena") or an id ("le07"), and defaults to the
	// campaign's first.
	campaign: string,
	level:    string,
	row:      int,
	// -plugins <dir>: one more plugins root, searched before $DR_PLUGINS
	// (D52). The level editor plays what it exports from one.
	plugins:  string,
}

settings_parse :: proc(args: []string) -> (s: Settings) {
	for i := 1; i < len(args); i += 1 {
		// A flag's value, if it has one.
		value := i + 1 < len(args) ? args[i + 1] : ""
		switch args[i] {
		case "-classic":
			s.classic = true
		case "-highrefreshrate":
			s.high_refresh_rate = true
		case "-diagnostics":
			s.diagnostics = true
		case "-fullscreen":
			s.fullscreen = true
		case "-campaign":
			s.campaign = value
			i += 1
		case "-level":
			s.level = value
			i += 1
		case "-row":
			s.row = max(strconv.parse_int(value) or_else 0, 0)
			i += 1
		case "-plugins":
			s.plugins = value
			i += 1
		}
	}
	return
}

// Whether the launch flags start play without the menus.
settings_play_now :: proc(s: Settings) -> bool {
	return s.level != "" || s.row > 0
}
