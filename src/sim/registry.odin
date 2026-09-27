package sim

import "base:runtime"
import "core:slice"

// A fixed-size list filled by registration steps: what the core and the
// plugins register -- systems, stages, prefab builders, hooks, components
// -- and the presentation's render systems and overlays. Fixed-size, so
// registering allocates nothing and a registry is the same in every run of
// a build.
Registry :: struct($T: typeid, $N: int) {
	items: [N]T,
	count: int,
}

// Adds item, and returns its index. A full registry is a bug in whoever
// sized it: the assertion names the register call that found it full.
registry_add :: proc(r: ^Registry($T, $N), item: T, loc := #caller_location) -> int {
	assert(r.count < N, "sim: a registry is full", loc)
	r.items[r.count] = item
	r.count += 1
	return r.count - 1
}

registry_items :: #force_inline proc "contextless" (r: ^Registry($T, $N)) -> []T {
	return r.items[:r.count]
}

// ---------------------------------------------------------------------------
// Registration steps
// ---------------------------------------------------------------------------

// What a package registers, it registers in a step it names from its
// `@(init)` procedure, and register_all runs every step in a fixed order:
// by stage, then by name. The order registries fill in gives ids --
// plugins', components', effect kinds' -- and breaks ties between systems,
// and peers exchange those ids, so it must not depend on the compiler.
// Odin runs `@(init)` procedures after those of the packages they import,
// but orders unrelated packages differently for different targets: the
// Windows build of v0.1.166 registered movement's components after
// collision's and passives after loadout, so a Linux host's mods meant
// other plugins to a Windows guest, whose snapshot then failed its catalog
// check (a guest crashed when the reward screen opened, and again on
// rejoining; decisions.md D50).
Register_Stage :: enum u8 {
	Core, // the simulation's own components and systems
	Plugin, // each plugin's session content; reads nothing another plugin registers
	Presentation, // the renderer's own systems
	View, // each plugin's presentation; may read its plugin's ids
}

Register_Step :: struct {
	stage: Register_Stage,
	name:  string, // unique; its package's path, and what it registers when a package has several
	run:   proc(),
}

@(private = "file")
register_steps: Registry(Register_Step, 64)
@(private = "file")
registered_all: bool

// Called from registration steps only (sim.register_step).
register_step :: proc "contextless" (stage: Register_Stage, name: string, run: proc()) {
	context = runtime.default_context()
	registry_add(&register_steps, Register_Step{stage, name, run})
}

// Runs the registration steps, once, before anything reads a registry:
// first thing in every program's main, and in the tests' set-up.
register_all :: proc() {
	if registered_all {
		return
	}
	registered_all = true
	steps := registry_items(&register_steps)
	slice.sort_by(steps, proc(a, b: Register_Step) -> bool {
		return a.stage != b.stage ? a.stage < b.stage : a.name < b.name
	})
	for s, i in steps {
		assert(i == 0 || s.name != steps[i - 1].name, "sim: two registration steps share a name")
		s.run()
	}
}

// Whether register_all has run: what builds a session checks first.
registered :: proc "contextless" () -> bool {
	return registered_all
}

// A digest of everything peers must register alike: the component
// catalog, the plugins, the systems and stages, and the weapon keys, in
// id order. Netplay peers compare it in their Hello, and refuse each other
// when it differs, rather than meet a snapshot or a mod they read another
// way.
registration_hash :: proc "contextless" () -> u64 {
	h := hasher()
	name :: proc "contextless" (h: ^Hasher, s: string) {
		hash_u64(h, u64(len(s)))
		hash_bytes(h, raw_data(s), len(s))
	}
	hash_u64(&h, catalog_hash())
	for p in registered_plugins() {
		name(&h, p.name)
		hash_u64(&h, u64(p.session))
	}
	for s in registered_systems() {
		name(&h, s.name)
	}
	for s in registered_player_stages() {
		name(&h, s.name)
	}
	for s in registered_entity_stages() {
		name(&h, s.name)
	}
	for k in registered_weapon_keys() {
		name(&h, k.name)
	}
	return h.sum
}
