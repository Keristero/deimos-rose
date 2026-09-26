package prefs

import "dr:sim"

// Settings the mods add: what the Extra Preferences plugin shows on its
// page (notes/ecs-refactor.md). A plugin registers each of its settings
// from the @(init) of its view/ package -- not the plugin's own, which
// stays pure for the simulation (mise run purity) while this package
// formats text -- and the page lists them, while their plugin is on.
//
// Saving and loading come from the registry, by key, so a setting's key is
// its name in the save file for good: renaming one drops everyone's value.

MAX_SETTINGS :: 32

Setting_Kind :: enum {
	Toggle, // 0 or 1
	Hue,    // degrees, 0..359
}

Setting :: struct {
	plugin:  sim.Plugin_ID, // shown, and in effect, only while it is on
	key:     string,        // in the save file
	label:   string,
	kind:    Setting_Kind,
	default: int,
}

// A setting's index in the registry, and in Prefs.settings.
Setting_ID :: distinct int

@(private = "file")
settings: [MAX_SETTINGS]Setting

@(private = "file")
setting_count: int

// Called from `@(init)` procedures only, like sim.plugin_register.
setting_register :: proc(s: Setting) -> Setting_ID {
	assert(setting_count < MAX_SETTINGS, "prefs: too many settings")
	for other in settings[:setting_count] {
		assert(other.key != s.key, "prefs: two settings share a key")
	}
	settings[setting_count] = s
	setting_count += 1
	return Setting_ID(setting_count - 1)
}

registered_settings :: proc "contextless" () -> []Setting {
	return settings[:setting_count]
}

// Clamps or wraps a value to what its kind allows.
setting_clean :: proc(id: Setting_ID, v: int) -> int {
	switch settings[id].kind {
	case .Toggle:
		return v != 0 ? 1 : 0
	case .Hue:
		return hue_wrap(v)
	}
	return v
}

setting_by_key :: proc(key: string) -> (Setting_ID, bool) {
	for s, i in settings[:setting_count] {
		if s.key == key {
			return Setting_ID(i), true
		}
	}
	return {}, false
}

// Turns a mod on with what it depends on, or off with what depends on it:
// the Mods page never leaves a mod on without its dependencies.
mod_toggle :: proc(mods: ^sim.Mods, id: sim.Plugin_ID) {
	if int(id) in mods^ {
		mods^ = sim.mods_resolve(mods^ - {int(id)})
	} else {
		mods^ = sim.mods_with_deps(mods^ + {int(id)})
	}
}
