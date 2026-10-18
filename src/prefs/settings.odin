package prefs

import "dr:sim"

// Settings the mods add: what the Extra Preferences plugin shows on its
// page (notes/ecs-refactor.md). A plugin registers each of its settings
// from the registration step of its view/ package -- not the plugin's own, which
// stays pure for the simulation (mise run purity) while this package
// formats text -- and the page lists them, while their plugin is on.
//
// Saving and loading come from the registry, by key, so a setting's key is
// its name in the save file for good: renaming one drops everyone's value.

MAX_SETTINGS :: 32

Setting_Kind :: enum {
	Toggle, // 0 or 1
	Hue,    // degrees, 0..359
	Percent, // 0..100, a slider
}

Setting :: struct {
	plugin:  sim.Plugin_ID, // shown, and in effect, only while it is on
	key:     string,        // in the save file
	label:   string,
	kind:    Setting_Kind,
	default: int,
	// A Hue that is a player's colour: 1 for player 1's (and yours in
	// netplay, where the lobby shows and sends it), 2 for player 2's in a
	// local game; 0 for any other setting. The game colours each player
	// by these, whichever plugin registers them.
	player:  int,
}

// A setting's index in the registry, and in Prefs.settings.
Setting_ID :: distinct int

// Called from registration steps only (sim.register_step), like sim.plugin_register.
setting_register :: proc(s: Setting) -> Setting_ID {
	assert(shared.setting_count < MAX_SETTINGS, "prefs: too many settings")
	for other in shared.settings[:shared.setting_count] {
		assert(other.key != s.key, "prefs: two settings share a key")
	}
	shared.settings[shared.setting_count] = s
	shared.setting_count += 1
	return Setting_ID(shared.setting_count - 1)
}

registered_settings :: proc "contextless" () -> []Setting {
	return shared.settings[:shared.setting_count]
}

// The setting that holds player `n`'s colour (Setting.player), if one is
// registered.
player_hue_setting :: proc "contextless" (n: int) -> (Setting_ID, bool) {
	for s, i in shared.settings[:shared.setting_count] {
		if s.kind == .Hue && s.player == n {
			return Setting_ID(i), true
		}
	}
	return {}, false
}

// The plugin that offers the Extras page, where every plugin's settings
// are: the page opens only while it is on. With none registered, it never
// does. Called from a registration step.
settings_page_register :: proc(plugin: sim.Plugin_ID) {
	shared.settings_page = plugin
}

// The plugin that offers the Extras page, or CORE when none does.
settings_page_plugin :: proc "contextless" () -> sim.Plugin_ID {
	return shared.settings_page
}

// Clamps or wraps a value to what its kind allows.
setting_clean :: proc(id: Setting_ID, v: int) -> int {
	switch shared.settings[id].kind {
	case .Toggle:
		return v != 0 ? 1 : 0
	case .Hue:
		return hue_wrap(v)
	case .Percent:
		return clamp(v, 0, 100)
	}
	return v
}

setting_by_key :: proc(key: string) -> (Setting_ID, bool) {
	for s, i in shared.settings[:shared.setting_count] {
		if s.key == key {
			return Setting_ID(i), true
		}
	}
	return {}, false
}

// Turns a mod on with what it depends on (and the companions that
// completes), or off with what depends on it: the Mods page never leaves a
// mod on without its dependencies.
mod_toggle :: proc(mods: ^sim.Mods, id: sim.Plugin_ID) {
	if int(id) in mods^ {
		mods^ = sim.mods_resolve(mods^ - {int(id)})
	} else {
		mods^ = sim.mods_switch_on(mods^, {int(id)})
	}
}
