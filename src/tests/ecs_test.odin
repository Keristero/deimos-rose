package tests

import "base:runtime"
import "core:testing"

import "dr:plugins/fps_unlock"
import "dr:plugins/loadout"
import "dr:sim"
import ecs "dr:third_party/odecs"

// The ECS host (sim/ecs.odin): layouts, the entity kinds a world is built
// with, and snapshots that depend only on the world's contents.

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

// A matrix is laid out element by element, in case its columns are padded
// (they are not, in the Odin this builds with).
Test_Matrix :: struct {
	flag: u8,
	m:    matrix[3, 3]f32,
}

// An empty array holds nothing, and a tag has no fields at all.
Test_Empty_Array :: struct {
	none: [0]u32,
	n:    i32,
}

Test_Tag :: struct {}

@(init)
register_test_components :: proc "contextless" () {
	context = runtime.default_context()
	// On every pool entity in a session with 30FPS Unlock, which no real
	// session names: something padded to scribble on.
	sim.kind_component(.Pool, Test_Padded{}, fps_unlock.ID)
	sim.component_register(Test_Dense)
	sim.component_register(Test_Padded_Array)
	sim.component_register(Test_Matrix)
	sim.component_register(Test_Empty_Array)
	sim.component_register(Test_Tag)
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

// A matrix's elements are data, and the padding before it is not; an empty
// array and a tag lay out nothing.
@(test)
component_layouts_cover_matrices_and_empty_types :: proc(t: ^testing.T) {
	m := type_of_id(sim.component_id(Test_Matrix))
	testing.expect_value(t, len(m.runs), 2)
	testing.expect_value(t, m.runs[0], sim.Byte_Run{0, 1})
	testing.expect_value(t, m.runs[1], sim.Byte_Run{4, 36})
	empty := type_of_id(sim.component_id(Test_Empty_Array))
	testing.expect_value(t, len(empty.runs), 1)
	testing.expect_value(t, empty.runs[0], sim.Byte_Run{0, 4})
	testing.expect_value(t, len(type_of_id(sim.component_id(Test_Tag)).runs), 0)
}

// Registering a type again is a no-op: a plugin and the core may both ask
// for the same component.
@(test)
component_registration_is_idempotent :: proc(t: ^testing.T) {
	n := len(sim.component_types())
	id := sim.component_id(Test_Dense)
	sim.component_register(Test_Dense)
	testing.expect_value(t, len(sim.component_types()), n)
	testing.expect_value(t, sim.component_id(Test_Dense), id)
}

@(private = "file")
world_state :: proc(e: ^sim.Ecs) -> sim.State {
	return sim.State{ecs = e}
}

@(private = "file")
pool_padded :: proc(e: ^sim.Ecs, i: int) -> ^Test_Padded {
	return ecs.get_component(e.world, e.ids[.Pool][i], Test_Padded)
}

// Every entity has its kind's components from the start, a plugin's only
// in a session with the plugin on, each holding the value it was given.
@(test)
entities_start_with_their_kinds_components :: proc(t: ^testing.T) {
	plain := sim.ecs_create({})
	defer sim.ecs_destroy(plain)
	with := sim.ecs_create({int(loadout.ID)})
	defer sim.ecs_destroy(with)
	a, b := world_state(plain), world_state(with)
	testing.expect(t, sim.single(&a, sim.Clock) != nil)
	testing.expect(t, sim.single(&a, loadout.Loadout) == nil)
	testing.expect(t, sim.player_component(&a, 1, loadout.Loadout_Slots) == nil)
	testing.expect(t, sim.single(&b, loadout.Loadout) != nil)
	slots := sim.player_component(&b, 1, loadout.Loadout_Slots)
	testing.expect_value(t, slots.spare, sim.NO_WEAPON)
	testing.expect_value(t, slots.loadout[0], sim.NO_WEAPON)
	testing.expect(t, pool_padded(plain, 0) == nil)
	testing.expect_value(t, len(plain.pool_links), sim.MAX_ENTITIES)
	testing.expect_value(t, len(plain.group_links), sim.MAX_GROUPS)
}

// Each pool slot's view is its own entity's components.
@(test)
views_are_each_entitys_own :: proc(t: ^testing.T) {
	e := sim.ecs_create({})
	defer sim.ecs_destroy(e)
	s := world_state(e)
	for i in 0 ..< i32(sim.MAX_ENTITIES) {
		v := sim.entity_at(&s, i)
		testing.expect_value(t, v.actor, ecs.get_component(e.world, e.ids[.Pool][i], sim.Actor))
		testing.expect_value(t, v.obj, ecs.get_component(e.world, e.ids[.Pool][i], sim.Game_Object))
	}
	testing.expect_value(t, sim.player_at(&s, 1).ship, ecs.get_component(e.world, e.ids[.Player][1], sim.Ship))
	testing.expect_value(t, sim.weapons_of(&s, 1).aim, ecs.get_component(e.world, e.ids[.Crosshair][1], sim.Crosshair))
}

// Resetting a world puts every entity back to its start values.
@(test)
a_reset_world_holds_its_start_values :: proc(t: ^testing.T) {
	e := sim.ecs_create({int(loadout.ID)})
	defer sim.ecs_destroy(e)
	fresh := digest(e)
	s := world_state(e)
	sim.single(&s, sim.Clock).time = 5
	sim.entity_at(&s, 7).number = 9
	sim.player_component(&s, 0, loadout.Loadout_Slots).spare = 2
	testing.expect(t, digest(e) != fresh)
	sim.ecs_reset(e)
	testing.expect_value(t, digest(e), fresh)
	testing.expect_value(t, sim.player_component(&s, 0, loadout.Loadout_Slots).spare, sim.NO_WEAPON)
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

// Padding is not state: two worlds holding equal values, whatever is in
// the bytes between them, write and hash alike.
@(test)
snapshots_depend_only_on_contents :: proc(t: ^testing.T) {
	mods := sim.Mods{int(fps_unlock.ID)}
	a := sim.ecs_create(mods)
	defer sim.ecs_destroy(a)
	b := sim.ecs_create(mods)
	defer sim.ecs_destroy(b)
	for i in 0 ..< 10 {
		pool_padded(a, i)^ = {a = u8(i), b = i32(i) * 3}
		p := pool_padded(b, i)
		p^ = {a = u8(i), b = i32(i) * 3}
		(transmute(^[12]u8)p)[1] = 0xAA // scribble on padding
	}
	testing.expect_value(t, digest(a), digest(b))
	sa, sb := snapshot(a), snapshot(b)
	testing.expect_value(t, len(sa), len(sb))
	testing.expect(t, string(sa) == string(sb))
	testing.expect_value(t, len(sa), sim.ecs_written_size(a))
}

@(test)
snapshots_restore_the_world :: proc(t: ^testing.T) {
	e := sim.ecs_create({int(fps_unlock.ID)})
	defer sim.ecs_destroy(e)
	s := world_state(e)
	sim.single(&s, sim.Clock).time = 1
	pool_padded(e, 5).a = 2
	sim.entity_at(&s, 7).number = 3
	saved := snapshot(e)
	before := digest(e)

	sim.single(&s, sim.Clock).time = 99
	pool_padded(e, 5)^ = {}
	sim.entity_at(&s, 7).number = 4
	testing.expect(t, digest(e) != before)

	rest, ok := sim.ecs_read(e, saved)
	testing.expect(t, ok)
	testing.expect_value(t, len(rest), 0)
	testing.expect_value(t, digest(e), before)
	testing.expect_value(t, sim.single(&s, sim.Clock).time, i32(1))
	testing.expect_value(t, pool_padded(e, 5).a, 2)
	testing.expect_value(t, sim.entity_at(&s, 7).number, i32(3))
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
	for st in sim.registered_player_stages() {
		append(&items, sim.Order_Item{st.name, st.after, st.before})
	}
	testing.expect_value(t, len(sim.schedule_unknown(items[:], context.temp_allocator)), 0)
	_, ok = sim.schedule(items[:], context.temp_allocator)
	testing.expect(t, ok, "the player stages' order has a cycle")
	clear(&items)
	for st in sim.registered_entity_stages() {
		append(&items, sim.Order_Item{st.name, st.after, st.before})
	}
	testing.expect_value(t, len(sim.schedule_unknown(items[:], context.temp_allocator)), 0)
	_, ok = sim.schedule(items[:], context.temp_allocator)
	testing.expect(t, ok, "the entity stages' order has a cycle")
}

// A snapshot that is not one this build could have written for this
// world -- another build's catalog, a world built for other plugins, cut
// short, too short to hold even its header -- is refused whole, and the
// world is left as it was.
@(test)
snapshots_from_elsewhere_change_nothing :: proc(t: ^testing.T) {
	e := sim.ecs_create({})
	defer sim.ecs_destroy(e)
	other := sim.ecs_create({int(loadout.ID)})
	defer sim.ecs_destroy(other)
	s := world_state(e)
	sim.entity_at(&s, 1).number = 1
	saved := snapshot(e)
	sim.entity_at(&s, 1).number = 5
	before := digest(e)

	corrupt := make([]byte, len(saved), context.temp_allocator)
	copy(corrupt, saved)
	corrupt[0] ~= 0xff
	cases := [?]struct {
		what: string,
		data: []byte,
	} {
		{"shorter than its header", saved[:10]},
		{"another build's catalog", corrupt},
		{"another world's shape", snapshot(other)},
		{"cut off in its data", saved[:len(saved) - 1]},
	}
	for c in cases {
		_, ok := sim.ecs_read(e, c.data)
		testing.expectf(t, !ok, "%s: must be refused", c.what)
		testing.expectf(t, digest(e) == before, "%s: must change nothing", c.what)
	}
}
