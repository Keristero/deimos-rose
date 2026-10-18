package tests

// One copy of every package's state (Phase 10 stage 2, decisions.md D83):
// binding points a plugin's copy of a package at the game's block. These
// bind tables of their own, standing in for a plugin's module and the
// game's, so they run without loading a library.

import "core:testing"

import "dr:blocks"
import "dr:sim"

@(private = "file")
Counter :: struct {
	n:      int,
	merged: int, // what a merge carried in
}

@(private = "file")
Other :: struct {
	n: f32,
}

// Adds the local block's count into the bound one, as sim carries a
// plugin's queued steps into the game's.
@(private = "file")
merge_counter :: proc(local, bound: rawptr) {
	(^Counter)(bound).merged += (^Counter)(local).n
}

@(private = "file")
table_of :: proc(items: ..blocks.Block) -> (t: blocks.Table) {
	for b, i in items {
		t.items[i] = b
	}
	t.count = len(items)
	return
}

// A plugin's copy reads and writes the game's state once bound, and what
// it made before binding is merged in once.
@(test)
binding_shares_the_hosts_block :: proc(t: ^testing.T) {
	game_block, plugin_block := Counter{n = 1}, Counter{n = 5}
	game_ptr, plugin_ptr := &game_block, &plugin_block
	host := table_of({name = "pkg", ptr = (^rawptr)(&game_ptr), type = Counter, merge = merge_counter})
	local := table_of({name = "pkg", ptr = (^rawptr)(&plugin_ptr), type = Counter, merge = merge_counter})

	err, _ := blocks.bind_tables(&local, &host)
	testing.expect_value(t, err, blocks.Bind_Error.None)
	testing.expect(t, plugin_ptr == &game_block)
	testing.expect_value(t, game_block.merged, 5)
	plugin_ptr.n += 1
	testing.expect_value(t, game_block.n, 2)

	// Binding again changes nothing and merges nothing.
	err, _ = blocks.bind_tables(&local, &host)
	testing.expect_value(t, err, blocks.Bind_Error.None)
	testing.expect_value(t, game_block.merged, 5)
}

// A package built from other sources binds nothing at all, and is named.
@(test)
binding_refuses_a_different_type :: proc(t: ^testing.T) {
	game_a, game_b := Counter{}, Counter{}
	plugin_a, plugin_b := Counter{}, Other{}
	ga, gb, pa, pb := &game_a, &game_b, &plugin_a, &plugin_b
	host := table_of({name = "a", ptr = (^rawptr)(&ga), type = Counter}, {name = "b", ptr = (^rawptr)(&gb), type = Counter})
	local := table_of({name = "a", ptr = (^rawptr)(&pa), type = Counter}, {name = "b", ptr = (^rawptr)(&pb), type = Other})

	err, name := blocks.bind_tables(&local, &host)
	testing.expect_value(t, err, blocks.Bind_Error.Type_Mismatch)
	testing.expect_value(t, name, "b")
	testing.expect(t, pa == &plugin_a) // "a" came first, and is still the plugin's own
}

// A package the game lacks, another plugin's, joins the game's table, so
// the next plugin that carries it shares the first one's copy.
@(test)
binding_joins_a_plugins_own_package :: proc(t: ^testing.T) {
	first, second := Counter{n = 3}, Counter{}
	fp, sp := &first, &second
	host: blocks.Table
	one := table_of({name = "plugins/x", ptr = (^rawptr)(&fp), type = Counter})
	two := table_of({name = "plugins/x", ptr = (^rawptr)(&sp), type = Counter})

	err, _ := blocks.bind_tables(&one, &host)
	testing.expect_value(t, err, blocks.Bind_Error.None)
	testing.expect_value(t, host.count, 1)
	testing.expect(t, fp == &first)

	err, _ = blocks.bind_tables(&two, &host)
	testing.expect_value(t, err, blocks.Bind_Error.None)
	testing.expect_value(t, host.count, 1)
	testing.expect(t, sp == &first)
	testing.expect_value(t, sp.n, 3)
}

// A table with no room for a plugin's packages binds none of them.
@(test)
binding_refuses_a_full_table :: proc(t: ^testing.T) {
	block := Counter{}
	p := &block
	host: blocks.Table
	host.count = blocks.MAX_BLOCKS
	local := table_of({name = "plugins/x", ptr = (^rawptr)(&p), type = Counter})
	err, _ := blocks.bind_tables(&local, &host)
	testing.expect_value(t, err, blocks.Bind_Error.Full)
	testing.expect_value(t, host.count, blocks.MAX_BLOCKS)
}

// Every package that keeps state declares its block, under its import path.
@(test)
packages_declare_their_blocks :: proc(t: ^testing.T) {
	for name in ([?]string{"sim", "sim/systems/collision_system", "data", "prefs", "render", "ui", "plugins/new_weapons", "plugins/passives"}) {
		_, ok := blocks.find(blocks.table(), name)
		testing.expectf(t, ok, "no block for %s", name)
	}
}

// sim's merge carries a plugin's queued registration steps into the
// game's, dropping those the game has: sim's own, which every copy of sim
// queues too.
@(test)
sim_merge_carries_a_plugins_steps :: proc(t: ^testing.T) {
	b, ok := blocks.find(blocks.table(), "sim")
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, b.type, typeid_of(sim.Shared))

	game, plugin := new(sim.Shared), new(sim.Shared)
	defer free(game)
	defer free(plugin)
	nop :: proc() {}
	sim.registry_add(&game.register_steps, sim.Register_Step{name = "sim", run = nop})
	sim.registry_add(&plugin.register_steps, sim.Register_Step{name = "sim", run = nop})
	sim.registry_add(&plugin.register_steps, sim.Register_Step{name = "plugins/x", run = nop})

	b.merge(plugin, game)
	steps := sim.registry_items(&game.register_steps)
	testing.expect_value(t, len(steps), 2)
	if len(steps) == 2 {
		testing.expect_value(t, steps[1].name, "plugins/x")
	}
}
