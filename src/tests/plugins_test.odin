package tests

import "core:testing"

import "dr:game"
import "dr:net"
import "dr:plugins/easy_mode"
import netplay_plugin "dr:plugins/netplay"
import "dr:plugins/new_weapons"
import "dr:plugins/passives"
import "dr:sim"

// The session plugins the game turns on for Easy Mode, New Weapons and
// netplay, with what they depend on: what a Start from a build before
// the mods were sent turns on (game/flow.odin's mods_from_flags).
session_mods :: proc(easy, weapons: bool, online := false) -> sim.Mods {
	want: sim.Mods
	if online {
		want += {int(netplay_plugin.ID)}
	}
	if easy {
		want += {int(easy_mode.ID)}
	}
	if weapons {
		want += {int(new_weapons.ID)}
	}
	return sim.mods_session(sim.mods_with_deps(want))
}

@(test)
plugins_bring_their_dependencies :: proc(t: ^testing.T) {
	mods := session_mods(true, false)
	testing.expect(t, int(easy_mode.ID) in mods)
	testing.expect(t, int(passives.ID) in mods)
	// Extra Preferences, which both need, changes nothing in a session.
	extra, ok := sim.plugin_find("extra_prefs")
	testing.expect(t, ok)
	testing.expect(t, int(extra) not_in mods)
	testing.expect(t, int(extra) in sim.mods_with_deps({int(easy_mode.ID)}))
}

@(test)
plugins_without_their_dependencies_are_off :: proc(t: ^testing.T) {
	testing.expect_value(t, sim.mods_resolve({int(easy_mode.ID)}), sim.Mods{})
	all := sim.mods_with_deps({int(easy_mode.ID), int(new_weapons.ID)})
	testing.expect_value(t, sim.mods_resolve(all), all)
}

@(test)
plugins_have_unique_names :: proc(t: ^testing.T) {
	seen := make(map[string]bool, context.temp_allocator)
	for p, i in sim.registered_plugins()[1:] {
		testing.expectf(t, !seen[p.name], "plugin %d: %q registered twice", i + 1, p.name)
		seen[p.name] = true
		for d in p.deps {
			_, ok := sim.plugin_find(d)
			testing.expectf(t, ok, "%s depends on %q, which nobody registered", p.name, d)
		}
	}
}

// The names of a schedule's items, in order.
@(private = "file")
scheduled_names :: proc(registered: []$T, mods: sim.Mods) -> []string {
	order: [64]u8
	n := sim.order_registered(registered, mods, order[:])
	out := make([]string, n, context.temp_allocator)
	for idx, i in order[:n] {
		out[i] = registered[idx].name
	}
	return out
}

// The systems a step runs, leaving out those that set a session up.
@(private = "file")
step_systems :: proc(mods: sim.Mods) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	registered := sim.registered_systems()
	for name in scheduled_names(registered, mods) {
		for &sys in registered {
			if sys.name == name && sys.kind != .Setup {
				append(&out, name)
			}
		}
	}
	return out[:]
}

@(private = "file")
expect_names :: proc(t: ^testing.T, got, want: []string, loc := #caller_location) {
	ok := len(got) == len(want)
	for i in 0 ..< min(len(got), len(want)) {
		ok &&= got[i] == want[i]
	}
	testing.expectf(t, ok, "got %v, want %v", got, want, loc = loc)
}

// With every session plugin on, each system and stage falls where the core
// ran it before it became a plugin's; with none, the core's order is the
// original's alone.
@(test)
plugins_take_their_places_in_the_step :: proc(t: ^testing.T) {
	all := session_mods(true, true, online = true)
	systems := step_systems(all)
	expect_names(t, systems[:3], {"netplay_pause", "reward_screen", "loadout_screen"})
	expect_names(t, systems[len(systems) - 3:], {"reward_open", "loadout_open", "level_transition"})
	stages := scheduled_names(sim.registered_player_stages(), all)
	expect_names(t, stages, {
		"defence_bonus", "player_state", "read_input", "player_look", "fire",
		"shield_regen", "risky_reward", "calm", "player_move",
	})
	core := step_systems({})
	expect_names(t, core[:1], {"step_events"})
	expect_names(t, core[len(core) - 2:], {"clock", "level_transition"})
}

// A Start without mods, from an older build, turns on what its flags did;
// the flags sent beside the mods say the same to one.
@(test)
plugins_from_start_flags :: proc(t: ^testing.T) {
	for easy in ([]bool{false, true}) {
		for weapons in ([]bool{false, true}) {
			flags: u8
			if easy {
				flags |= net.START_EASY
			}
			if weapons {
				flags |= net.START_LOADOUT
			}
			mods := session_mods(easy, weapons)
			testing.expect_value(t, game.mods_from_flags(flags), mods)
			testing.expect_value(t, game.flags_from_mods(mods), flags)
		}
	}
}

// Netplay's plugin is in a session exactly when it is online, whatever the
// mods passed in say.
@(test)
plugins_netplay_only_online :: proc(t: ^testing.T) {
	all := sim.Mods{int(netplay_plugin.ID), int(easy_mode.ID)}
	testing.expect_value(t, game.session_from_mods(1, {}, .Single, all).mods, sim.Mods{int(easy_mode.ID)})
	testing.expect_value(t, game.session_from_mods(1, {}, .Co_Op, {int(easy_mode.ID)}, online = true).mods, all)
}
