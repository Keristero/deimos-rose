package sim

// The entity component system the simulation's state lives in (D39, D47).
//
// odecs holds the world, and this file uses only its public API. What the
// simulation adds on top:
// - a catalog of component types, each with a fixed id and a byte layout
//   that leaves out padding, so a world can be written out and hashed the
//   same on every machine;
// - entity kinds: the session's entity, the players, their crosshairs, the
//   groups and the entity pool, each built with the components the core
//   and the session's plugins give that kind;
// - writing a world out, reading it back and hashing it, for rollback,
//   reconnection and desync detection.
//
// A world is built once per session, every entity with all its components,
// as the original preallocates its pool (FUN_0041d1d0), and nothing is
// added or removed after. odecs moves a component only when an entity's
// components change or an entity is added, so every view taken once the
// world is built (entity_at, player_at, single) stays good for the
// session, and both peers' worlds are laid out alike.

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import ecs "dr:third_party/odecs"

// ---------------------------------------------------------------------------
// The component catalog
// ---------------------------------------------------------------------------

MAX_COMPONENTS :: 128

// Which components something has, by catalog id.
Component_Mask :: bit_set[0 ..< MAX_COMPONENTS; u128]

// A stretch of a component's bytes that holds data. Padding is left out, so
// two worlds holding equal values write equal bytes.
Byte_Run :: struct {
	offset, size: i32,
}

Component_Type :: struct {
	type:     typeid,
	name:     string,
	size:     int,
	runs:     []Byte_Run,
	// odecs's calls take the type at compile time; these are them, made
	// for this type, so a world can be walked by the catalog.
	register: proc(w: ^ecs.World),
	get:      proc(w: ^ecs.World, id: ecs.EntityID) -> rawptr,
	table:    proc(w: ^ecs.World, arch: ^ecs.Archetype) -> []byte,
}

@(private = "file")
catalog: [MAX_COMPONENTS]Component_Type
@(private = "file")
catalog_count: int
@(private = "file")
run_pool: [8192]Byte_Run
@(private = "file")
run_used: int
@(private = "file")
run_bytes: int // data bytes laid out so far, to tell padded types from dense ones

// Each component type's catalog id, one static per type. Reading it is a
// load, where odecs's own lookup hashes the typeid: the sim reads
// components tens of times per entity per step.
@(private)
component_slot :: #force_inline proc "contextless" ($T: typeid) -> ^i32 {
	@(static) id: i32 = -1
	return &id
}

// The components of `types`, for a query (Entity_Stage.with). Every one
// must be registered.
mask_of :: proc(types: ..typeid) -> (m: Component_Mask) {
	outer: for t in types {
		for c, i in catalog[:catalog_count] {
			if c.type == t {
				m += {i}
				continue outer
			}
		}
		panic("ecs: a query names a component that is not registered")
	}
	return
}

// Adds T to the catalog. Called from `@(init)` procedures only, the sim's
// own and each plugin's, so the catalog is complete and fixed before any
// world exists, and ids are the same in every world of the process.
//
// T must be plain data: a snapshot copies its bytes, so a pointer, slice,
// string or map would copy an address, not a value.
component_register :: proc($T: typeid) {
	slot := component_slot(T)
	if slot^ >= 0 {
		return
	}
	assert(catalog_count < MAX_COMPONENTS, "ecs: too many component types")
	ti := type_info_of(T)
	first := run_used
	if !layout_runs(ti, 0) {
		panic("ecs: a component must be plain data (no pointers, slices, strings, maps or unions)")
	}
	name := ""
	if n, ok := ti.variant.(runtime.Type_Info_Named); ok {
		name = n.name
	}
	catalog[catalog_count] = Component_Type {
		type = T,
		name = name,
		size = size_of(T),
		runs = run_pool[first:run_used],
		register = proc(w: ^ecs.World) {
			ecs.register_component(w, T)
		},
		get = proc(w: ^ecs.World, id: ecs.EntityID) -> rawptr {
			return ecs.get_component(w, id, T)
		},
		table = proc(w: ^ecs.World, arch: ^ecs.Archetype) -> []byte {
			return slice.to_bytes(ecs.get_table(w, arch, T))
		},
	}
	slot^ = i32(catalog_count)
	catalog_count += 1
}

component_types :: proc "contextless" () -> []Component_Type {
	return catalog[:catalog_count]
}

component_id :: #force_inline proc "contextless" ($T: typeid) -> int {
	return int(component_slot(T)^)
}

// A digest of the catalog: the names, sizes and layouts in id order. Two
// builds can only exchange snapshots if theirs match.
catalog_hash :: proc "contextless" () -> u64 {
	h := hasher()
	for c in catalog[:catalog_count] {
		hash_bytes(&h, raw_data(c.name), len(c.name))
		hash_u64(&h, u64(c.size))
		for r in c.runs {
			hash_u64(&h, u64(r.offset) | u64(r.size) << 32)
		}
	}
	return h.sum
}

@(private = "file")
emit_run :: proc(offset, size: int) {
	if size == 0 {
		return
	}
	run_bytes += size
	if run_used > 0 {
		last := &run_pool[run_used - 1]
		if int(last.offset + last.size) == offset {
			last.size += i32(size)
			return
		}
	}
	assert(run_used < len(run_pool), "ecs: component layouts too fragmented")
	run_pool[run_used] = {i32(offset), i32(size)}
	run_used += 1
}

// Appends the data-holding byte runs of a value of type ti at `base`.
@(private = "file")
layout_runs :: proc(ti: ^runtime.Type_Info, base: int) -> bool {
	#partial switch v in ti.variant {
	case runtime.Type_Info_Named:
		return layout_runs(v.base, base)
	case runtime.Type_Info_Integer, runtime.Type_Info_Rune, runtime.Type_Info_Float,
	     runtime.Type_Info_Complex, runtime.Type_Info_Quaternion, runtime.Type_Info_Boolean,
	     runtime.Type_Info_Enum, runtime.Type_Info_Bit_Set, runtime.Type_Info_Bit_Field,
	     runtime.Type_Info_Simd_Vector:
		emit_run(base, ti.size)
		return true
	case runtime.Type_Info_Array:
		return layout_elems(v.elem, v.elem_size, v.count, base)
	case runtime.Type_Info_Enumerated_Array:
		return layout_elems(v.elem, v.elem_size, v.count, base)
	case runtime.Type_Info_Matrix:
		// Column-major, each column elem_stride long, of which the first
		// row_count are elements: element by element, so padding is left out.
		for i in 0 ..< v.elem_stride * v.column_count {
			if i % v.elem_stride < v.row_count {
				emit_run(base + i * v.elem_size, v.elem_size)
			}
		}
		return true
	case runtime.Type_Info_Struct:
		if .raw_union in v.flags || v.soa_kind != .None {
			return false
		}
		for i in 0 ..< int(v.field_count) {
			if !layout_runs(v.types[i], base + int(v.offsets[i])) {
				return false
			}
		}
		return true
	}
	return false
}

@(private = "file")
layout_elems :: proc(elem: ^runtime.Type_Info, elem_size, count, base: int) -> bool {
	if count == 0 {
		return true
	}
	before := run_bytes
	if !layout_runs(elem, base) {
		return false
	}
	// An element with no padding is all data, and so is the array: the
	// other elements extend the run.
	if run_bytes - before == elem_size {
		emit_run(base + elem_size, elem_size * (count - 1))
		return true
	}
	for i in 1 ..< count {
		layout_runs(elem, base + i * elem_size)
	}
	return true
}

// ---------------------------------------------------------------------------
// Entity kinds
// ---------------------------------------------------------------------------

// What each of the world's entities is. A world holds kind_count(kind) of
// each, made in this order.
Kind :: enum u8 {
	Session,   // the singletons (components_session.odin)
	Player,    // components_player.odin
	Crosshair, // each player's ground crosshair
	Group,     // components_entity.odin
	Pool,      // the entity pool
}

kind_count :: #force_inline proc "contextless" (k: Kind) -> int {
	switch k {
	case .Session:
		return 1
	case .Player, .Crosshair:
		return MAX_PLAYERS
	case .Group:
		return MAX_GROUPS
	case .Pool:
		return MAX_ENTITIES
	}
	return 0
}

@(private = "file")
Kind_Component :: struct {
	kind:      Kind,
	component: int,
	plugin:    Plugin_ID,
	value:     rawptr, // what each entity of the kind starts with
}

@(private = "file")
kind_components: [MAX_COMPONENTS]Kind_Component
@(private = "file")
kind_component_count: int
// u128s, for the alignment of any component.
@(private = "file")
start_values: [1024]u128
@(private = "file")
start_used: int

// Gives every entity of `kind` a T, starting as `value`, in a session with
// `plugin` on. Called from `@(init)` procedures only, like
// component_register, which it does for T.
kind_component :: proc(kind: Kind, value: $T, plugin := CORE) {
	component_register(T)
	id := component_id(T)
	for kc in kind_components[:kind_component_count] {
		assert(kc.kind != kind || kc.component != id, "ecs: a kind is given the same component twice")
	}
	assert(kind_component_count < len(kind_components), "ecs: too many kind components")
	start_used = (start_used + align_of(T) - 1) &~ (align_of(T) - 1)
	assert(start_used + size_of(T) <= size_of(start_values), "ecs: too many start values")
	p := &([^]byte)(&start_values)[start_used]
	start_used += size_of(T)
	(^T)(p)^ = value
	kind_components[kind_component_count] = {kind, id, plugin, p}
	kind_component_count += 1
}

@(private = "file")
kind_component_on :: #force_inline proc "contextless" (kc: Kind_Component, mods: Mods) -> bool {
	return kc.plugin == CORE || int(kc.plugin) in mods
}

// ---------------------------------------------------------------------------
// Worlds
// ---------------------------------------------------------------------------

Ecs :: struct {
	world:       ^ecs.World,
	allocator:   runtime.Allocator,
	mods:        Mods, // the plugins whose components it holds
	ids:         [Kind][]ecs.EntityID,
	// Views into the world, found once it is built (see the top of the
	// file).
	entities:    []Entity,
	groups:      []^Group,
	players:     [MAX_PLAYERS]Player,
	pool_links:  []Link,
	group_links: []Link,
	singletons:  [MAX_COMPONENTS]rawptr, // the session entity's, by catalog id
	player_part: [MAX_PLAYERS][MAX_COMPONENTS]rawptr,
	// Every data component's table, by catalog id, then in the order
	// odecs keeps its archetypes: what a snapshot holds.
	tables:      [dynamic]Table,
	// The tables' components and sizes, which only a world built alike
	// shares, and how many bytes a written world takes.
	shape:       u64,
	size:        int,
}

Table :: struct {
	component: int,
	arch:      ^ecs.Archetype,
}

// A world for a session with `mods`: every entity of every kind, holding
// its start values.
ecs_create :: proc(mods: Mods, allocator := context.allocator) -> ^Ecs {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	e := new(Ecs, allocator)
	e.allocator = allocator
	e.mods = mods
	e.world = ecs.create_world(allocator, allocator)
	w := e.world
	for c in catalog[:catalog_count] {
		c.register(w)
	}
	parts := make([dynamic]any, context.temp_allocator)
	for kind in Kind {
		clear(&parts)
		for kc in kind_components[:kind_component_count] {
			if kc.kind == kind && kind_component_on(kc, mods) {
				append(&parts, any{kc.value, catalog[kc.component].type})
			}
		}
		e.ids[kind] = make([]ecs.EntityID, kind_count(kind), allocator)
		for &id in e.ids[kind] {
			id = ecs.add_entity(w, ..parts[:])
		}
	}
	find_views(e)
	return e
}

// Every view into the world, now that nothing more will be added to it.
@(private = "file")
find_views :: proc(e: ^Ecs) {
	w := e.world
	get :: proc(w: ^ecs.World, id: ecs.EntityID, $T: typeid) -> ^T {
		return ecs.get_component(w, id, T)
	}
	e.entities = make([]Entity, MAX_ENTITIES, e.allocator)
	for id, i in e.ids[.Pool] {
		e.entities[i] = {
			obj     = get(w, id, Game_Object),
			actor   = get(w, id, Actor),
			anim    = get(w, id, Anim),
			motion  = get(w, id, Motion),
			owned   = get(w, id, Owned),
			spawner = get(w, id, Spawner),
			effects = get(w, id, Effects),
			shaped  = get(w, id, Shaped),
		}
	}
	e.groups = make([]^Group, MAX_GROUPS, e.allocator)
	for id, i in e.ids[.Group] {
		e.groups[i] = get(w, id, Group)
	}
	for id, i in e.ids[.Player] {
		aim := e.ids[.Crosshair][i]
		e.players[i] = {
			obj     = get(w, id, Game_Object),
			ship    = get(w, id, Ship),
			purse   = get(w, id, Purse),
			hull    = get(w, id, Hull),
			surge   = get(w, id, Overload),
			weapons = {handler = get(w, id, Weapon_Handler), crosshair = get(w, aim, Game_Object), aim = get(w, aim, Crosshair)},
		}
	}
	e.pool_links = kind_table(e, .Pool, Link)
	e.group_links = kind_table(e, .Group, Link)
	for c, i in catalog[:catalog_count] {
		e.singletons[i] = c.get(w, e.ids[.Session][0])
		for id, p in e.ids[.Player] {
			e.player_part[p][i] = c.get(w, id)
		}
	}
	h := hasher()
	for c, i in catalog[:catalog_count] {
		if c.size == 0 {
			continue // a tag has no table
		}
		for arch in ecs.query_raw(w, {c.type}) {
			append(&e.tables, Table{i, arch})
			rows := len(ecs.get_entities(arch))
			hash_u64(&h, u64(i) | u64(rows) << 32)
			for r in c.runs {
				e.size += rows * int(r.size)
			}
		}
	}
	e.shape = h.sum
}

// T of every entity of a kind, by index: the kind's table, whose rows are
// its entities in the order they were made.
@(private = "file")
kind_table :: proc(e: ^Ecs, kind: Kind, $T: typeid) -> []T {
	arch := ecs.get_entity_archetype(e.world, e.ids[kind][0])
	assert(slice.equal(ecs.get_entities(arch), e.ids[kind]), "ecs: a kind shares its table")
	return ecs.get_table(e.world, arch, T)
}

ecs_destroy :: proc(e: ^Ecs) {
	if e == nil {
		return
	}
	allocator := e.allocator
	ecs.delete_world(e.world)
	for ids in e.ids {
		delete(ids, allocator)
	}
	delete(e.entities, allocator)
	delete(e.groups, allocator)
	delete(e.tables)
	free(e, allocator)
}

// Puts every entity back to its start values.
ecs_reset :: proc(e: ^Ecs) {
	for kind in Kind {
		arch := ecs.get_entity_archetype(e.world, e.ids[kind][0])
		for kc in kind_components[:kind_component_count] {
			if kc.kind != kind || !kind_component_on(kc, e.mods) {
				continue
			}
			c := &catalog[kc.component]
			rows := catalog[kc.component].table(e.world, arch)
			for at := 0; at < len(rows); at += c.size {
				runtime.mem_copy_non_overlapping(&rows[at], kc.value, c.size)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Snapshots
// ---------------------------------------------------------------------------

// FNV-1a over 8-byte words, then the bytes left over: the same on every
// machine, which reads the words little-endian.
Hasher :: struct {
	sum: u64,
}

hasher :: proc "contextless" () -> Hasher {
	return {0xcbf29ce484222325}
}

hash_bytes :: proc "contextless" (h: ^Hasher, p: rawptr, n: int) {
	b := ([^]u8)(p)
	words := n / 8
	for i in 0 ..< words {
		h.sum ~= u64(intrinsics.unaligned_load((^u64le)(&b[i * 8])))
		h.sum *= 0x100000001b3
	}
	for i in words * 8 ..< n {
		h.sum ~= u64(b[i])
		h.sum *= 0x100000001b3
	}
}

hash_u64 :: proc "contextless" (h: ^Hasher, v: u64) {
	x := v
	hash_bytes(h, &x, 8)
}

@(private = "file")
HEADER :: 16

// The header: the catalog and the world's shape, so a world only reads
// what a world built alike wrote.
@(private = "file")
header_of :: proc(e: ^Ecs) -> [2]u64 {
	return {catalog_hash(), e.shape}
}

// The world's state: its tables, row by row, each row's data bytes, into
// out (ecs_written_size bytes). The rows are the entities in the order they
// were made, which no step changes, so equal worlds write equal bytes.
@(private = "file")
ecs_pack :: proc(e: ^Ecs, out: []byte) {
	header := header_of(e)
	runtime.mem_copy_non_overlapping(raw_data(out), &header, HEADER)
	at := HEADER
	for t in e.tables {
		c := &catalog[t.component]
		rows := c.table(e.world, t.arch)
		if len(c.runs) == 1 && int(c.runs[0].size) == c.size {
			copy(out[at:], rows) // no padding: the table as it is
			at += len(rows)
			continue
		}
		for row := 0; row < len(rows); row += c.size {
			for r in c.runs {
				runtime.mem_copy_non_overlapping(&out[at], &rows[row + int(r.offset)], int(r.size))
				at += int(r.size)
			}
		}
	}
}

// Appends the world's state to buf.
ecs_write :: proc(e: ^Ecs, buf: ^[dynamic]byte) {
	start := len(buf)
	resize(buf, start + ecs_written_size(e))
	ecs_pack(e, buf[start:])
}

// Mixes the world's state into h: the same bytes ecs_write would write.
ecs_hash :: proc(e: ^Ecs, h: ^Hasher) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	out := make([]byte, ecs_written_size(e), context.temp_allocator)
	ecs_pack(e, out)
	hash_bytes(h, raw_data(out), len(out))
}

// How many bytes ecs_write writes for e.
ecs_written_size :: proc "contextless" (e: ^Ecs) -> int {
	return HEADER + e.size
}

// Whether data starts with a world e can read.
ecs_readable :: proc(e: ^Ecs, data: []byte) -> bool {
	if len(data) < HEADER + e.size {
		return false
	}
	header: [2]u64
	runtime.mem_copy_non_overlapping(&header, raw_data(data), HEADER)
	return header == header_of(e)
}

// Makes the world hold what `data` (from ecs_write) holds, and returns the
// bytes after it. Fails, leaving the world unchanged, if the data came from
// a build with a different catalog or a world built otherwise, or is cut
// short.
ecs_read :: proc(e: ^Ecs, data: []byte) -> (rest: []byte, ok: bool) {
	if !ecs_readable(e, data) {
		return data, false
	}
	at := HEADER
	for t in e.tables {
		c := &catalog[t.component]
		rows := c.table(e.world, t.arch)
		if len(c.runs) == 1 && int(c.runs[0].size) == c.size {
			copy(rows, data[at:at + len(rows)])
			at += len(rows)
			continue
		}
		for row := 0; row < len(rows); row += c.size {
			for r in c.runs {
				runtime.mem_copy_non_overlapping(&rows[row + int(r.offset)], &data[at], int(r.size))
				at += int(r.size)
			}
		}
	}
	return data[at:], true
}
