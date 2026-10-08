package tests

import "core:os"
import "core:strings"
import "core:testing"

import "dr:game"
import "dr:plugins/chaingun"
import "dr:plugins/easy_mode"
import netplay_plugin "dr:plugins/netplay"
import "dr:plugins/new_weapons"
import "dr:plugins/passives"
import "dr:sim"

// The session plugins the game turns on for Easy Mode, New Weapons and
// netplay, with what they depend on.
session_mods :: proc(easy, weapons: bool, online := false) -> sim.Mods {
	want: sim.Mods
	if online {
		want += {int(netplay_plugin.id())}
	}
	if easy {
		want += {int(easy_mode.id())}
	}
	if weapons {
		want += {int(new_weapons.id()), int(chaingun.id())}
	}
	return sim.mods_session(sim.mods_switch_on({}, want))
}

@(test)
plugins_bring_their_dependencies :: proc(t: ^testing.T) {
	mods := session_mods(true, false)
	testing.expect(t, int(easy_mode.id()) in mods)
	testing.expect(t, int(passives.id()) in mods)
	// Extra Preferences, which both need, changes nothing in a session.
	extra, ok := sim.plugin_find("extra_prefs")
	testing.expect(t, ok)
	testing.expect(t, int(extra) not_in mods)
	testing.expect(t, int(extra) in sim.mods_with_deps({int(easy_mode.id())}))
}

@(test)
plugins_without_their_dependencies_are_off :: proc(t: ^testing.T) {
	testing.expect_value(t, sim.mods_resolve({int(easy_mode.id())}), sim.Mods{})
	all := sim.mods_with_deps({int(easy_mode.id()), int(new_weapons.id())})
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

// Registration runs by stage, then by name (sim.register_all), not in the
// order the compiler runs the packages' `@(init)`s, which differs between
// targets: so a plugin's id follows its name, the same on every platform
// (D50).
@(test)
plugins_ids_follow_their_names :: proc(t: ^testing.T) {
	ps := sim.registered_plugins()[1:]
	for i in 1 ..< len(ps) {
		testing.expectf(t, ps[i - 1].name < ps[i].name, "%q has id %d, after %q", ps[i].name, i + 1, ps[i - 1].name)
	}
	testing.expect(t, sim.registered())
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

// Every plugin folder with code is in the build: game/plugins.odin imports
// it, or nothing registers it and its content is never offered.
@(test)
plugins_folders_are_all_in_the_build :: proc(t: ^testing.T) {
	entries, err := os.read_all_directory_by_path("plugins", context.temp_allocator)
	if !testing.expect(t, err == nil, "the plugins folder must be there") {
		return
	}
	for e in entries {
		if e.type != .Directory {
			continue
		}
		files, _ := os.read_all_directory_by_path(e.fullpath, context.temp_allocator)
		for f in files {
			if strings.has_suffix(f.name, ".odin") {
				_, ok := sim.plugin_find(e.name)
				testing.expectf(t, ok, "plugins/%s is not registered: is it imported in game/plugins.odin?", e.name)
				break
			}
		}
	}
}

// Netplay's plugin is in a session exactly when it is online, whatever the
// mods passed in say.
@(test)
plugins_netplay_only_online :: proc(t: ^testing.T) {
	all := sim.Mods{int(netplay_plugin.id()), int(easy_mode.id())}
	testing.expect_value(t, game.session_from_mods(1, {}, .Single, all).mods, sim.Mods{int(easy_mode.id())})
	testing.expect_value(t, game.session_from_mods(1, {}, .Co_Op, {int(easy_mode.id())}, online = true).mods, all)
}

// The Mods page lists each mod under the one it needs most deeply, by
// label, whatever order the packages registered them in.
@(test)
mods_page_lists_a_tree_of_needs :: proc(t: ^testing.T) {
	want := []string{"extra_prefs", "fps_unlock", "accent", "hitstop", "loadout", "new_weapons", "chaingun", "new_weapon_passives", "water", "passives", "easy_mode", "lighting", "wind", "netplay"}
	got := game.mods_order()
	testing.expect_value(t, len(got), len(want))
	for id, i in got {
		if i < len(want) {
			testing.expect_value(t, sim.registered_plugins()[id].name, want[i])
		}
	}
}

// A plugin's own weapon is in play exactly while that plugin is on; an
// original weapon always is (D49).
@(test)
plugins_own_weapons_follow_their_plugin :: proc(t: ^testing.T) {
	s: sim.State
	mine := sim.Weapon{extra = true, plugin = chaingun.id()}
	original := sim.Weapon{}
	s.session.mods = session_mods(false, true)
	testing.expect(t, sim.weapon_allowed(&s, &mine))
	s.session.mods -= {int(chaingun.id())}
	testing.expect(t, !sim.weapon_allowed(&s, &mine), "not with its plugin off, New Weapons or not")
	testing.expect(t, sim.weapon_allowed(&s, &original))
	s.session.mods = {}
	testing.expect(t, sim.weapon_allowed(&s, &original))
}

// A plugin whose content did not load is dropped, with what needs it.
@(test)
plugins_without_their_content_are_off :: proc(t: ^testing.T) {
	want := sim.mods_with_deps({int(chaingun.id()), int(easy_mode.id())})
	both := sim.Mods{int(new_weapons.id()), int(chaingun.id())}
	testing.expect_value(t, sim.mods_with_content(want, both), want)
	testing.expect_value(t, sim.mods_with_content(want, {int(new_weapons.id())}), want - {int(chaingun.id())})
	testing.expect_value(t, sim.mods_with_content(want, {int(chaingun.id())}), want - both)
}

// New Weapons as one switch (the lobby's) brings the Chaingun with it.
@(test)
new_weapons_switch_brings_the_chaingun :: proc(t: ^testing.T) {
	testing.expect_value(t, sim.mods_default_dependants(new_weapons.id()), sim.Mods{int(chaingun.id())})
}
