package sim

// Plugins: what Deimos Rose adds to the original, each in a folder of its
// own under plugins/ that registers itself, its components and its systems
// from a registration step (register_step, notes/ecs-refactor.md). The core, this
// package, is the original game, and runs alone when no plugin is on: in
// classic mode, in films and for the oracle.
//
// A plugin names the plugins it depends on. That is what lets it use their
// components; it is on only while they are. Run order between systems is a
// separate matter, settled by the systems themselves (schedule.odin).

MAX_PLUGINS :: 31

// A plugin's index in the registry, from 1; CORE is the original game.
// Indexes follow registration order, which is by name (register_all), the
// same on every platform: peers agree on them when they run the same
// build, as netplay requires and checks (registration_hash).
Plugin_ID :: distinct u8

CORE :: Plugin_ID(0)

// A set of plugins, by ID.
Mods :: bit_set[0 ..= MAX_PLUGINS; u32]

Plugin :: struct {
	name:        string, // saved in preferences and named by dependants
	label:       string, // on the Mods screen
	description: string,
	deps:        []string,
	// Whether it changes the simulation. A session plugin is part of the
	// Session, the same on every peer; any other is each player's own
	// (how the game looks or is set up) and never reaches the simulation.
	session:     bool,
	// On for a player who has never visited the Mods page.
	default_on:  bool,
	// Needs its own content, under assets/extra/<name>: off when that did
	// not load (Defs.content, mods_with_content).
	content:     bool,
}

// Slot 0, CORE's, is empty.
@(private = "file")
plugins := Registry(Plugin, MAX_PLUGINS + 1){count = 1}

// Called from registration steps only (sim.register_step), like system_register; `deps` must
// outlive the call. Returns the plugin's ID, for its systems and hooks.
plugin_register :: proc(p: Plugin) -> Plugin_ID {
	return Plugin_ID(registry_add(&plugins, p))
}

// Every registered plugin, indexed by ID; [CORE] is empty.
registered_plugins :: proc "contextless" () -> []Plugin {
	return registry_items(&plugins)
}

plugin_find :: proc "contextless" (name: string) -> (Plugin_ID, bool) {
	for p, i in registry_items(&plugins)[1:] {
		if p.name == name {
			return Plugin_ID(i + 1), true
		}
	}
	return CORE, false
}

// `want` without any plugin whose dependencies are not all in it, repeated
// until nothing more drops out. A dependency nobody registered is never
// met.
mods_resolve :: proc "contextless" (want: Mods) -> Mods {
	mods := want - {int(CORE)}
	for {
		dropped := false
		for id in 1 ..< plugins.count {
			if id not_in mods {
				continue
			}
			for dep in plugins.items[id].deps {
				d, ok := plugin_find(dep)
				if !ok || int(d) not_in mods {
					mods -= {id}
					dropped = true
					break
				}
			}
		}
		if !dropped {
			return mods
		}
	}
}

// `want` with the plugins each one depends on, and theirs, added.
mods_with_deps :: proc "contextless" (want: Mods) -> Mods {
	mods := want - {int(CORE)}
	for {
		added := false
		for id in 1 ..< plugins.count {
			if id not_in mods {
				continue
			}
			for dep in plugins.items[id].deps {
				if d, ok := plugin_find(dep); ok && int(d) not_in mods {
					mods += {int(d)}
					added = true
				}
			}
		}
		if !added {
			return mods
		}
	}
}

// `mods` without the plugins that need content `loaded` does not hold, and
// what needs them.
mods_with_content :: proc "contextless" (mods: Mods, loaded: Mods) -> Mods {
	missing: Mods
	for id in 1 ..< plugins.count {
		if plugins.items[id].content && id not_in loaded {
			missing += {id}
		}
	}
	return mods_resolve(mods - missing)
}

// The default-on plugins that need `id`, directly or through others: what
// a switch that stands for a whole group (the lobby's New Weapons) turns
// back on with it, where each has no switch of its own.
mods_default_dependants :: proc "contextless" (id: Plugin_ID) -> Mods {
	under := Mods{int(id)}
	for {
		added := false
		for p in 1 ..< plugins.count {
			if p in under || !plugins.items[p].default_on {
				continue
			}
			for dep in plugins.items[p].deps {
				if d, ok := plugin_find(dep); ok && int(d) in under {
					under += {p}
					added = true
					break
				}
			}
		}
		if !added {
			return under - {int(id)}
		}
	}
}

// The session plugins in `mods`: what a Session carries.
mods_session :: proc "contextless" (mods: Mods) -> (out: Mods) {
	for id in 1 ..< plugins.count {
		if id in mods && plugins.items[id].session {
			out += {id}
		}
	}
	return
}

// Whether a plugin runs in this session. CORE always does.
mod_on :: #force_inline proc "contextless" (s: ^State, id: Plugin_ID) -> bool {
	return id == CORE || int(id) in s.session.mods
}
