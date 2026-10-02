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
//
// A data plugin has no code: a folder with a plugin.json and content,
// found at startup (data.plugins_discover) and declared before
// register_all, which registers it after every compiled plugin (D52).

MAX_PLUGINS :: 63

// A plugin's index in the registry, from 1; CORE is the original game.
// Indexes follow registration order, which is by name (register_all), the
// same on every platform, compiled plugins first and then data plugins:
// peers agree on them when they run the same build with the same plugin
// folders, as netplay requires and checks (registration_hash).
Plugin_ID :: distinct u8

CORE :: Plugin_ID(0)

// A set of plugins, by ID.
Mods :: bit_set[0 ..= MAX_PLUGINS; u64]

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
	// What two plugins add together, on wherever its dependencies all
	// are: it comes on as the last of them does (mods_switch_on), and a
	// player turns it off alone. Unlike default_on, it never brings its
	// dependencies in: New Weapons' passives come with Passive Upgrades
	// and New Weapons, but turn neither on.
	companion:   bool,
	// Needs its own content, in plugins/<name>/ (D51): off when that did
	// not load (Defs.content, mods_with_content).
	content:     bool,
	// From its plugin.json, if it has one: peers compare it (registration_hash).
	version:     string,
	// Registered from a plugin.json alone, with no code in the build (D52).
	data_only:   bool,
	// A digest of its content files (plugin_digest_set), 0 before they are
	// read: peers with different content refuse each other rather than
	// desync.
	digest:      u64,
}

// Slot 0, CORE's, is empty.
@(private = "file")
plugins := Registry(Plugin, MAX_PLUGINS + 1){count = 1}

@(private = "file")
declared: []Plugin

// The plugins found as folders at startup, in name order: before
// register_all, which registers each after the compiled plugins. One whose
// name a compiled plugin has only gives that plugin its label, description
// and version, where they are set. `list` must outlive the program.
plugins_declare :: proc(list: []Plugin) {
	assert(!registered(), "sim: plugins declared after register_all")
	declared = list
}

// register_all's, once every compiled plugin has registered.
@(private)
plugins_register_declared :: proc() {
	for p in declared {
		if id, ok := plugin_find(p.name); ok {
			c := &plugins.items[id]
			if p.label != "" {
				c.label = p.label
			}
			if p.description != "" {
				c.description = p.description
			}
			c.version = p.version
			continue
		}
		d := p
		d.data_only, d.content = true, true
		plugin_register(d)
	}
}

// Records the digest of a plugin's content (data.plugins_digest).
plugin_digest_set :: proc "contextless" (id: Plugin_ID, digest: u64) {
	plugins.items[id].digest = digest
}

// The first plugin `id` depends on that is not in the build, if any: why
// it can never be on.
plugin_missing_dep :: proc "contextless" (id: Plugin_ID) -> (dep: string, missing: bool) {
	for d in plugins.items[id].deps {
		if _, ok := plugin_find(d); !ok {
			return d, true
		}
	}
	return "", false
}

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
			if id in mods && !deps_in(id, mods) {
				mods -= {id}
				dropped = true
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

// `mods` with `on` turned on: with what each needs (mods_with_deps), and
// the companions whose dependencies that completes. A companion whose
// dependencies were all on already stays as it was: a player who turned
// it off has it off still.
mods_switch_on :: proc "contextless" (mods: Mods, on: Mods) -> Mods {
	out := mods_with_deps(mods + on)
	for {
		added := false
		for id in 1 ..< plugins.count {
			if id not_in out && plugins.items[id].companion && deps_in(id, out) && !deps_in(id, mods) {
				out += {id}
				added = true
			}
		}
		if !added {
			return out
		}
	}
}

// The companions that `mods` has every dependency of, on or not.
mods_companions :: proc "contextless" (mods: Mods) -> (out: Mods) {
	for id in 1 ..< plugins.count {
		if plugins.items[id].companion && deps_in(id, mods) {
			out += {id}
		}
	}
	return
}

@(private = "file")
deps_in :: proc "contextless" (id: int, mods: Mods) -> bool {
	for dep in plugins.items[id].deps {
		if d, ok := plugin_find(dep); !ok || int(d) not_in mods {
			return false
		}
	}
	return true
}

// The default-on plugins that need `id`, directly or through others: what
// a switch that stands for a whole group (the lobby's New Weapons) turns
// back on with it, where each has no switch of its own. Companions are
// not among them: turning the group on brings those (mods_switch_on).
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
