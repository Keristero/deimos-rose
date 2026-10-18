package sim

import "dr:blocks"

// Everything sim keeps between calls, in one block that a plugin's copy of
// sim is bound to (dr:blocks, decisions.md D83). Each field is described
// where it is used.
Shared :: struct {
	// registry.odin
	register_steps:  Registry(Register_Step, 64),
	registered_all:  bool,
	// plugins.odin; slot 0, CORE's, is empty and filled by the first plugin_register
	plugins:         Registry(Plugin, MAX_PLUGINS + 1),
	declared:        []Plugin,
	// ecs.odin
	catalog:         Registry(Component_Type, MAX_COMPONENTS),
	run_pool:        [8192]Byte_Run,
	run_used:        int,
	run_bytes:       int, // data bytes laid out so far, to tell padded types from dense ones
	kind_components: Registry(Kind_Component, MAX_COMPONENTS),
	start_values:    [1024]u128, // u128s, for the alignment of any component
	start_used:      int,
	// systems.odin
	systems:         Registry(System, MAX_SYSTEMS),
	player_stages:   Registry(Player_Stage, MAX_STAGES),
	stages:          Registry(Entity_Stage, MAX_STAGES),
	// prefabs.odin
	builders:        Registry(Prefab_Builder, MAX_PREFAB_BUILDERS),
	queries:         Registry(Query_Terms, MAX_PREFAB_QUERIES),
	term_pool:       [512]typeid,
	term_used:       int,
	// hooks.odin
	stat_providers:  Registry(Stat_Provider, MAX_HOOKS),
	holds:           Registry(Hold, MAX_HOOKS),
	choosers:        Registry(Weapon_Chooser, MAX_HOOKS),
	filters:         Registry(Weapon_Filter, MAX_HOOKS),
	fires:           Registry(Weapon_Fire, MAX_HOOKS),
	shot_hits:       Registry(Shot_Hit, MAX_HOOKS),
	// def_keys.odin, queue_effects.odin
	weapon_keys:     Registry(Def_Key, MAX_WEAPON_KEYS),
	effect_kinds:    Registry(typeid, MAX_EFFECT_KINDS),
	// profile.odin; not part of any session's state
	profile:         Profile,
}

// Zeroed, so it lies in .bss: an initialiser would write all of it into
// the executable.
@(private)
shared_block: Shared
@(private)
shared := &shared_block

@(init, private)
declare_shared :: proc "contextless" () {
	blocks.declare({name = "sim", ptr = (^rawptr)(&shared), type = Shared, merge = merge_shared})
}

// A plugin's `@(init)`s queue its registration steps in its own copy of
// sim before it is bound; they join the game's, and a step the game has
// already (one of sim's own, carried by every copy) is dropped by name.
@(private)
merge_shared :: proc(local, bound: rawptr) {
	from, into := (^Shared)(local), (^Shared)(bound)
	assert(!into.registered_all, "sim: a plugin bound after register_all")
	outer: for step in registry_items(&from.register_steps) {
		for have in registry_items(&into.register_steps) {
			if have.name == step.name {
				continue outer
			}
		}
		registry_add(&into.register_steps, step)
	}
}
