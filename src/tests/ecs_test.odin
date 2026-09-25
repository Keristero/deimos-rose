package tests

import "base:runtime"
import "core:testing"

import "dr:sim"

// The ECS host (sim/ecs.odin): layouts, fixed entities, moves between
// archetypes, and snapshots that depend only on the world's contents.

Test_Padded :: struct {
	a: u8,
	// three bytes of padding
	b: i32,
	c: bool,
	// three bytes of padding
}

Test_Dense :: struct {
	v: [3]f32,
	n: i32,
}

Test_Padded_Array :: struct {
	items: [2]Test_Padded,
}

@(init)
register_test_components :: proc "contextless" () {
	context = runtime.default_context()
	sim.component_register(Test_Padded)
	sim.component_register(Test_Dense)
	sim.component_register(Test_Padded_Array)
}

@(private = "file")
type_of_id :: proc(id: int) -> sim.Component_Type {
	return sim.component_types()[id]
}

@(test)
component_layouts_leave_out_padding :: proc(t: ^testing.T) {
	padded := type_of_id(sim.component_id(Test_Padded))
	testing.expect_value(t, len(padded.runs), 2)
	testing.expect_value(t, padded.runs[0], sim.Byte_Run{0, 1})
	testing.expect_value(t, padded.runs[1], sim.Byte_Run{4, 5})

	dense := type_of_id(sim.component_id(Test_Dense))
	testing.expect_value(t, len(dense.runs), 1)
	testing.expect_value(t, dense.runs[0], sim.Byte_Run{0, 16})

	arr := type_of_id(sim.component_id(Test_Padded_Array))
	testing.expect_value(t, len(arr.runs), 4)
	testing.expect_value(t, arr.runs[2], sim.Byte_Run{12, 1})
	testing.expect_value(t, arr.runs[3], sim.Byte_Run{16, 5})
}

@(test)
fixed_entities_start_empty :: proc(t: ^testing.T) {
	e := sim.ecs_create()
	defer sim.ecs_destroy(e)
	testing.expect_value(t, sim.components_of(e, sim.SESSION_ENTITY), sim.Component_Mask{})
	testing.expect(t, sim.get(e, sim.pool_entity(sim.MAX_ENTITIES - 1), Test_Dense) == nil)
}

@(test)
components_survive_moves_between_archetypes :: proc(t: ^testing.T) {
	e := sim.ecs_create()
	defer sim.ecs_destroy(e)
	id := sim.pool_entity(3)
	sim.add(e, id, Test_Dense{v = {1, 2, 3}, n = 4})
	sim.add(e, id, Test_Padded{a = 5, b = 6, c = true})
	testing.expect_value(t, sim.get(e, id, Test_Dense).n, 4)
	sim.remove(e, id, Test_Padded)
	testing.expect(t, !sim.has(e, id, Test_Padded))
	testing.expect_value(t, sim.get(e, id, Test_Dense).v, [3]f32{1, 2, 3})
}

// The sim holds a pointer to the entity it is processing while that entity
// spawns others into the same archetype: the columns must not move.
@(test)
component_pointers_survive_other_entities_arriving :: proc(t: ^testing.T) {
	e := sim.ecs_create()
	defer sim.ecs_destroy(e)
	p := sim.add(e, sim.pool_entity(0), Test_Dense{n = 42})
	for i in 1 ..< i32(sim.MAX_ENTITIES) {
		sim.add(e, sim.pool_entity(i), Test_Dense{n = i})
	}
	testing.expect_value(t, p, sim.get(e, sim.pool_entity(0), Test_Dense))
	testing.expect_value(t, p.n, 42)
}

@(private = "file")
snapshot :: proc(e: ^sim.Ecs) -> []byte {
	buf := make([dynamic]byte, context.temp_allocator)
	sim.ecs_write(e, &buf)
	return buf[:]
}

@(private = "file")
digest :: proc(e: ^sim.Ecs) -> u64 {
	h := sim.hasher()
	sim.ecs_hash(e, &h)
	return h.sum
}

@(test)
snapshots_depend_only_on_contents :: proc(t: ^testing.T) {
	// The same contents reached in different orders put the rows in
	// different places and leave different garbage in the padding.
	a := sim.ecs_create()
	defer sim.ecs_destroy(a)
	b := sim.ecs_create()
	defer sim.ecs_destroy(b)
	for i in i32(0) ..< 10 {
		sim.add(a, sim.pool_entity(i), Test_Padded{a = u8(i), b = i * 3})
	}
	for i := i32(9); i >= 0; i -= 1 {
		sim.add(b, sim.pool_entity(i), Test_Dense{})
		p := sim.add(b, sim.pool_entity(i), Test_Padded{a = u8(i), b = i * 3})
		(transmute(^[12]u8)p)[1] = 0xAA // scribble on padding
		sim.remove(b, sim.pool_entity(i), Test_Dense)
	}
	testing.expect_value(t, digest(a), digest(b))
	sa, sb := snapshot(a), snapshot(b)
	testing.expect_value(t, len(sa), len(sb))
	testing.expect(t, string(sa) == string(sb))
}

@(test)
snapshots_restore_the_world :: proc(t: ^testing.T) {
	e := sim.ecs_create()
	defer sim.ecs_destroy(e)
	sim.add(e, sim.SESSION_ENTITY, Test_Dense{n = 1})
	sim.add(e, sim.pool_entity(5), Test_Padded{a = 2})
	sim.add(e, sim.pool_entity(7), Test_Padded_Array{items = {{a = 3}, {c = true}}})
	saved := snapshot(e)
	before := digest(e)

	// Change values, add and take away components, then go back.
	sim.get(e, sim.SESSION_ENTITY, Test_Dense).n = 99
	sim.remove(e, sim.pool_entity(5), Test_Padded)
	sim.add(e, sim.pool_entity(6), Test_Dense{n = 6})
	sim.add(e, sim.pool_entity(7), Test_Dense{n = 7})
	testing.expect(t, digest(e) != before)

	rest, ok := sim.ecs_read(e, saved)
	testing.expect(t, ok)
	testing.expect_value(t, len(rest), 0)
	testing.expect_value(t, digest(e), before)
	testing.expect_value(t, sim.get(e, sim.SESSION_ENTITY, Test_Dense).n, 1)
	testing.expect_value(t, sim.get(e, sim.pool_entity(5), Test_Padded).a, 2)
	testing.expect(t, !sim.has(e, sim.pool_entity(6), Test_Dense))
	testing.expect(t, !sim.has(e, sim.pool_entity(7), Test_Dense))
	testing.expect_value(t, sim.get(e, sim.pool_entity(7), Test_Padded_Array).items[1].c, true)
}

@(test)
a_cut_short_snapshot_changes_nothing :: proc(t: ^testing.T) {
	e := sim.ecs_create()
	defer sim.ecs_destroy(e)
	sim.add(e, sim.pool_entity(1), Test_Dense{n = 1})
	saved := snapshot(e)
	sim.get(e, sim.pool_entity(1), Test_Dense).n = 2
	before := digest(e)
	_, ok := sim.ecs_read(e, saved[:len(saved) - 1])
	testing.expect(t, !ok)
	testing.expect_value(t, digest(e), before)
}

@(test)
schedule_keeps_registration_order_except_where_named :: proc(t: ^testing.T) {
	items := []sim.Order_Item {
		{name = "a"},
		{name = "b", after = {"d"}},
		{name = "c"},
		{name = "d", after = {"a", "missing"}},
	}
	order, ok := sim.schedule(items, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(order), 4)
	// d goes ahead of b, which needs it; c keeps its place.
	want := []int{0, 3, 1, 2}
	for w, i in want {
		testing.expect_value(t, order[i], w)
	}
	unknown := sim.schedule_unknown(items, context.temp_allocator)
	testing.expect_value(t, len(unknown), 1)
	testing.expect_value(t, unknown[0], "missing")
}

@(test)
schedule_rejects_a_cycle :: proc(t: ^testing.T) {
	items := []sim.Order_Item{{name = "a", after = {"b"}}, {name = "b", after = {"a"}}}
	_, ok := sim.schedule(items, context.temp_allocator)
	testing.expect(t, !ok)
}

@(test)
schedule_places_an_item_before_what_it_names :: proc(t: ^testing.T) {
	items := []sim.Order_Item{{name = "a"}, {name = "b"}, {name = "c", before = {"a"}}, {name = "d", before = {"gone"}}}
	order, ok := sim.schedule(items, context.temp_allocator)
	testing.expect(t, ok)
	want := []int{2, 0, 1, 3}
	for w, i in want {
		testing.expect_value(t, order[i], w)
	}
	unknown := sim.schedule_unknown(items, context.temp_allocator)
	testing.expect_value(t, len(unknown), 1)
}

// Every system and stage the registry holds places itself only against
// others it holds: a name nobody has is a typo, since a plugin's systems
// are registered whether it is enabled or not.
@(test)
registered_systems_name_only_registered_systems :: proc(t: ^testing.T) {
	items := make([dynamic]sim.Order_Item, context.temp_allocator)
	for sys in sim.registered_systems() {
		append(&items, sim.Order_Item{sys.name, sys.after, sys.before})
	}
	testing.expect_value(t, len(sim.schedule_unknown(items[:], context.temp_allocator)), 0)
	_, ok := sim.schedule(items[:], context.temp_allocator)
	testing.expect(t, ok, "the systems' order has a cycle")
	clear(&items)
	for st in sim.registered_entity_stages() {
		append(&items, sim.Order_Item{st.name, st.after, st.before})
	}
	testing.expect_value(t, len(sim.schedule_unknown(items[:], context.temp_allocator)), 0)
	_, ok = sim.schedule(items[:], context.temp_allocator)
	testing.expect(t, ok, "the entity stages' order has a cycle")
}
