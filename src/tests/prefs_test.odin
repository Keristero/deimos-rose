package tests

import "core:strings"
import "core:testing"

import "dr:plugins/accent"
import accent_view "dr:plugins/accent/view"
import "dr:plugins/easy_mode"
import "dr:plugins/extra_prefs"
import "dr:plugins/fps_unlock"
import "dr:plugins/loadout"
import netplay_plugin "dr:plugins/netplay"
import "dr:plugins/new_weapons"
import "dr:plugins/passives"
import "dr:prefs"
import "dr:sim"

@(test)
prefs_round_trip_through_the_save_format :: proc(t: ^testing.T) {
	p := prefs.defaults()
	p.sfx_volume, p.music_volume = 30, 0
	p.fullscreen, p.classic = true, true
	p.mods += {int(fps_unlock.ID)}
	p.settings[accent_view.HUE_P1] = 42
	prefs.bind(&p, 1, .Fire_Air, 1, prefs.KEY_SPACE) // moves Space off player 1
	text := prefs.format(&p, context.temp_allocator)
	got := prefs.parse(text)
	testing.expect_value(t, got, p)
}

@(test)
prefs_parse_keeps_defaults_for_what_it_does_not_understand :: proc(t: ^testing.T) {
	// A missing file, an older file, or a hand-edited typo each fall back
	// per setting rather than losing the lot.
	got := prefs.parse("music_volume=40\nsfx_volume=loud\np1.fire_air=1,2,3\np9.up=87,0\nbogus\np2.left=65,0\nclassic=yes\n")
	want := prefs.defaults()
	want.music_volume = 40
	want.bindings[1][.Left] = {prefs.KEY_A, prefs.KEY_NONE}
	// A was also player 1's default second Left key; the file's choice wins.
	want.bindings[0][.Left] = {prefs.KEY_LEFT, prefs.KEY_NONE}
	testing.expect_value(t, got, want)

	testing.expect_value(t, prefs.parse(""), prefs.defaults())
	testing.expect_value(t, prefs.parse("sfx_volume=250").sfx_volume, 100) // clamped
}

@(test)
prefs_bind_takes_a_key_off_everything_else :: proc(t: ^testing.T) {
	p := prefs.defaults()
	// W is player 1's alternate Up; giving it to player 2's Fire Air must
	// leave it bound exactly once.
	prefs.bind(&p, 1, .Fire_Air, 0, prefs.KEY_W)
	testing.expect_value(t, p.bindings[1][.Fire_Air][0], i32(prefs.KEY_W))
	testing.expect_value(t, p.bindings[0][.Up], [prefs.BINDING_SLOTS]i32{prefs.KEY_UP, prefs.KEY_NONE})
	count := 0
	for b in p.bindings {
		for keys in b {
			for k in keys {
				if k == prefs.KEY_W {
					count += 1
				}
			}
		}
	}
	testing.expect_value(t, count, 1)

	// KEY_NONE clears one slot without touching any other.
	prefs.bind(&p, 0, .Down, 0, prefs.KEY_NONE)
	testing.expect_value(t, p.bindings[0][.Down], [prefs.BINDING_SLOTS]i32{prefs.KEY_NONE, prefs.KEY_S})
	testing.expect_value(t, p.bindings[0][.Left], [prefs.BINDING_SLOTS]i32{prefs.KEY_LEFT, prefs.KEY_A})
}

@(test)
prefs_defaults_give_each_player_distinct_keys :: proc(t: ^testing.T) {
	// Player 2 had no keys at all before bindings; theirs must not overlap
	// player 1's, or local co-op would move both ships with one key.
	p := prefs.defaults()
	seen: map[i32]int
	defer delete(seen)
	for b, player in p.bindings {
		for keys, button in b {
			// Player 2 has no Pause key by default: the original had one
			// player and one pause key.
			if !(player == 1 && button == .Pause) {
				testing.expectf(t, keys[0] != prefs.KEY_NONE, "player %d %v has no key", player + 1, button)
			}
			for k in keys {
				if k == prefs.KEY_NONE {
					continue
				}
				if other, dup := seen[k]; dup {
					testing.expectf(t, false, "key %d bound for player %d and player %d", k, other + 1, player + 1)
				}
				seen[k] = player
			}
		}
	}
	testing.expect_value(t, len(p.bindings), sim.MAX_PLAYERS)
}

@(test)
prefs_volume_steps_stay_in_range :: proc(t: ^testing.T) {
	v := 95
	prefs.step_volume(&v, 1)
	testing.expect_value(t, v, 100)
	v = 5
	prefs.step_volume(&v, -1)
	testing.expect_value(t, v, 0)
	v = 50
	prefs.step_volume(&v, -1)
	testing.expect_value(t, v, 50 - prefs.VOLUME_STEP)
}

@(test)
prefs_parse_ignores_an_old_pause_binding :: proc(t: ^testing.T) {
	// Pause was bindable once before, saved as "pause" and defaulting to P
	// for player 1 -- so every file from then says p1.pause=80. The binding
	// is "pause_key" now, defaulting to Escape, and
	// the old line must not keep anyone off it.
	got := prefs.parse("p1.pause=80,0\np2.change_weapon=80,0\n")
	want := prefs.defaults()
	want.bindings[1][.Change_Air] = {prefs.KEY_P, prefs.KEY_NONE}
	testing.expect_value(t, got, want)
	testing.expect_value(t, got.bindings[0][.Pause], [prefs.BINDING_SLOTS]i32{prefs.KEY_ESCAPE, prefs.KEY_NONE})
	testing.expect(t, !strings.contains(prefs.format(&got, context.temp_allocator), "pause="))

	// A rebound Pause key survives the round trip.
	p := prefs.defaults()
	prefs.bind(&p, 0, .Pause, 0, prefs.KEY_P)
	testing.expect_value(t, prefs.parse(prefs.format(&p, context.temp_allocator)), p)
}

@(test)
netplay_name_round_trips_and_is_cleaned :: proc(t: ^testing.T) {
	p := prefs.defaults()
	testing.expect_value(t, prefs.name_string(&p.netplay_name), "")
	prefs.name_set(&p.netplay_name, "  Keristero  ")
	got := prefs.parse(prefs.format(&p, context.temp_allocator))
	testing.expect_value(t, prefs.name_string(&got.netplay_name), "Keristero")
	testing.expect_value(t, got, p)

	n: prefs.Name
	prefs.name_set(&n, "a\tbéc")
	testing.expect_value(t, prefs.name_string(&n), "abc") // printable ASCII only
	prefs.name_set(&n, "abcdefghijklmnopqrs uvwxyz")
	testing.expect_value(t, prefs.name_string(&n), "abcdefghijklmnopqrs") // cut at 20, trailing space dropped
	// Re-trimming a name in place, as netplay's name entry does on Enter,
	// used to wipe it: the text is a slice of the name being cleared.
	prefs.name_set(&n, " Kez ")
	prefs.name_set(&n, prefs.name_string(&n))
	testing.expect_value(t, prefs.name_string(&n), "Kez")
}

// Accent Color's settings keep the key names they had before there were
// mods, so an older save still loads them.
@(test)
prefs_settings_keep_their_keys :: proc(t: ^testing.T) {
	testing.expect_value(t, prefs.parse("accent_hue=-30").settings[accent_view.HUE_P1], 330)
	testing.expect_value(t, prefs.parse("accent_hue=725").settings[accent_view.HUE_P1], 5)
	testing.expect_value(t, prefs.parse("self_outline=7").settings[accent_view.SELF_OUTLINE], 1)
	testing.expect_value(t, prefs.parse("").settings[accent_view.HUE_P1], prefs.registered_settings()[accent_view.HUE_P1].default)
	// A save from before the P2 hue has player 2 in their original gold.
	testing.expect_value(t, prefs.parse("accent_hue=30").settings[accent_view.HUE_P2], 63)
}

// Mods are saved by name, not by ID, and a name this build does not know
// is dropped rather than failing the line.
@(test)
prefs_mods_round_trip_by_name :: proc(t: ^testing.T) {
	p := prefs.defaults()
	p.mods = sim.mods_with_deps({int(easy_mode.ID)})
	text := prefs.format(&p, context.temp_allocator)
	line := text[strings.index(text, "mods="):]
	line = line[:strings.index_byte(line, '\n')]
	for name in ([]string{"easy_mode", "passives", "extra_prefs"}) {
		testing.expectf(t, strings.contains(line, name), "%q is saved in %q", name, line)
	}
	testing.expect_value(t, prefs.parse(text).mods, p.mods)
	testing.expect_value(t, prefs.parse("mods=easy_mode,no_such_mod").mods, sim.Mods{int(easy_mode.ID)})
	testing.expect_value(t, prefs.parse("mods=").mods, sim.Mods{})
}

// A new player starts with Accent Color, New Weapons and Netplay on, and
// what those need.
@(test)
prefs_default_mods :: proc(t: ^testing.T) {
	want := sim.mods_with_deps({int(accent.ID), int(new_weapons.ID), int(netplay_plugin.ID)})
	testing.expect_value(t, prefs.defaults().mods, want)
	testing.expect_value(t, prefs.parse("").mods, want)
}

// A save from before the Mods page switched these features with a line
// each; they carry over into mods, until a mods line supersedes them.
@(test)
prefs_legacy_extras_become_mods :: proc(t: ^testing.T) {
	defaults := prefs.defaults().mods
	testing.expect_value(t, prefs.parse("high_refresh_rate=1").mods, defaults + {int(fps_unlock.ID)})
	testing.expect_value(t, prefs.parse("accent_colours=0").mods, defaults - {int(accent.ID)})
	testing.expect_value(t, prefs.parse("easy_mode=1").mods, sim.mods_with_deps(defaults + {int(easy_mode.ID)}))
	// Without New Weapons, the loadout it brought stays on: it is a mod of
	// its own now.
	testing.expect_value(t, prefs.parse("new_weapons=0").mods, defaults - {int(new_weapons.ID)})
	testing.expect_value(t, prefs.parse("mods=accent\neasy_mode=1").mods, sim.Mods{int(accent.ID)})
}

// Turning a mod on turns on what it needs; turning one off turns off what
// needs it.
@(test)
prefs_mod_toggle_follows_dependencies :: proc(t: ^testing.T) {
	mods: sim.Mods
	prefs.mod_toggle(&mods, easy_mode.ID)
	testing.expect_value(t, mods, sim.Mods{int(easy_mode.ID), int(passives.ID), int(extra_prefs.ID)})
	prefs.mod_toggle(&mods, extra_prefs.ID)
	testing.expect_value(t, mods, sim.Mods{})
	prefs.mod_toggle(&mods, new_weapons.ID)
	prefs.mod_toggle(&mods, loadout.ID)
	testing.expect_value(t, mods, sim.Mods{int(extra_prefs.ID)})
}
