package sim

// The entity component system the simulation's state lives in (D39).
//
// odecs stores the components. This file adds what the simulation needs on
// top of it:
// - a catalog of component types, each with a fixed id and a byte layout
//   that leaves out padding, so a world can be written out and hashed the
//   same on every machine;
// - a fixed set of entities, created once in a fixed order and never
//   destroyed, so every world numbers them alike;
// - moving an entity straight to the archetype for a set of components,
//   with room reserved so no move reallocates a column;
// - writing a world out, reading it back and hashing it, for rollback,
//   reconnection and desync detection.

import "base:runtime"
import ecs "dr:third_party/odecs"

// ---------------------------------------------------------------------------
// The component catalog
// ---------------------------------------------------------------------------

MAX_COMPONENTS :: 128

// Which components an entity has, by catalog id.
Component_Mask :: bit_set[0 ..< MAX_COMPONENTS; u128]

// A stretch of a component's bytes that holds data. Padding is left out, so
// two worlds holding equal values write equal bytes.
Byte_Run :: struct {
	offset, size: i32,
}

Component_Type :: struct {
	type:  typeid,
	name:  string,
	size:  int,
	runs:  []Byte_Run,
	// How many rows to reserve in each archetype holding it: see
	// ecs_set_components.
	rows:  int,
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

// Adds T to the catalog. Called from `@(init)` procedures only, the sim's
// own and each plugin's, so the catalog is complete and fixed before any
// world exists, and ids are the same in every world of the process.
//
// T must be plain data: a snapshot copies its bytes, so a pointer, slice,
// string or map would copy an address, not a value.
component_register :: proc($T: typeid, rows := MAX_ENTITIES) {
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
		rows = rows,
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

// odecs numbers components from 1, in registration order; the catalog from
// 0.
@(private = "file")
CID_BASE :: 1

@(private = "file")
cid_of :: #force_inline proc "contextless" (id: int) -> ecs.ComponentID {
	return ecs.ComponentID(id + CID_BASE)
}

@(private = "file")
id_of :: #force_inline proc "contextless" (cid: ecs.ComponentID) -> int {
	return int(cid) - CID_BASE
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
		// Column-major with padded columns: element by element.
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
// Worlds
// ---------------------------------------------------------------------------

// The fixed entities, in creation order. odecs numbers entities from 1 and
// never recycles one that is never destroyed, so these are their ids.
SESSION_ENTITY :: ecs.EntityID(1)
FIRST_PLAYER_ENTITY :: 2
FIRST_CROSSHAIR_ENTITY :: FIRST_PLAYER_ENTITY + MAX_PLAYERS
FIRST_GROUP_ENTITY :: FIRST_CROSSHAIR_ENTITY + MAX_PLAYERS
FIRST_POOL_ENTITY :: FIRST_GROUP_ENTITY + MAX_GROUPS
FIXED_ENTITIES :: FIRST_POOL_ENTITY + MAX_ENTITIES - 1

player_entity :: #force_inline proc "contextless" (i: i32) -> ecs.EntityID {
	return ecs.EntityID(FIRST_PLAYER_ENTITY + i)
}

crosshair_entity :: #force_inline proc "contextless" (i: i32) -> ecs.EntityID {
	return ecs.EntityID(FIRST_CROSSHAIR_ENTITY + i)
}

group_entity :: #force_inline proc "contextless" (i: i32) -> ecs.EntityID {
	return ecs.EntityID(FIRST_GROUP_ENTITY + i)
}

pool_entity :: #force_inline proc "contextless" (i: i32) -> ecs.EntityID {
	return ecs.EntityID(FIRST_POOL_ENTITY + i)
}

Ecs :: struct {
	world:      ^ecs.World,
	allocator:  runtime.Allocator,
	archetypes: map[Component_Mask]^ecs.Archetype,
}

ecs_create :: proc(allocator := context.allocator) -> ^Ecs {
	e := new(Ecs, allocator)
	e.allocator = allocator
	e.world = ecs.create_world(allocator, allocator)
	// An archetype that empties stays, with its reserved rows, for the next
	// entity to need it.
	e.world.auto_cleanup_archetypes = false
	e.archetypes = make(map[Component_Mask]^ecs.Archetype, allocator = allocator)
	for c, i in catalog[:catalog_count] {
		cid := ecs.register_component_dynamic(e.world, c.type)
		assert(cid == cid_of(i), "ecs: odecs numbered a component differently")
	}
	e.archetypes[{}] = e.world.empty_archetype
	for i in 1 ..= FIXED_ENTITIES {
		id := ecs.add_entity(e.world)
		assert(id == ecs.EntityID(i), "ecs: fixed entity numbered differently")
	}
	return e
}

ecs_destroy :: proc(e: ^Ecs) {
	if e == nil {
		return
	}
	allocator := e.allocator
	ecs.delete_world(e.world)
	delete(e.archetypes)
	free(e, allocator)
}

// Takes every component off every entity.
ecs_clear :: proc(e: ^Ecs) {
	for i in 1 ..= FIXED_ENTITIES {
		ecs_set_components(e, ecs.EntityID(i), {})
	}
}

// T on entity id, or nil. The pointer is good until the next structural
// change to the entity's archetype (D39).
get :: #force_inline proc "contextless" (e: ^Ecs, id: ecs.EntityID, $T: typeid) -> ^T {
	rec := &e.world.records[u64(id) & ecs.ENTITY_INDEX_MASK]
	arch := rec.archetype
	cid := cid_of(int(component_slot(T)^))
	for c, i in arch.signature {
		if c == cid {
			col := &arch.columns[arch.column_indices[i]]
			return cast(^T)&col.data[rec.row * size_of(T)]
		}
	}
	return nil
}

has :: #force_inline proc "contextless" (e: ^Ecs, id: ecs.EntityID, $T: typeid) -> bool {
	arch := e.world.records[u64(id) & ecs.ENTITY_INDEX_MASK].archetype
	cid := cid_of(int(component_slot(T)^))
	for c in arch.signature {
		if c == cid {
			return true
		}
	}
	return false
}

components_of :: proc "contextless" (e: ^Ecs, id: ecs.EntityID) -> (m: Component_Mask) {
	arch := e.world.records[u64(id) & ecs.ENTITY_INDEX_MASK].archetype
	for c in arch.signature {
		m += {id_of(c)}
	}
	return
}

// Moves entity id to the archetype holding exactly `mask`. Components it
// keeps keep their values; new ones start zeroed. One move, not one per
// component, so no in-between archetype is made.
//
// Each archetype reserves rows for as many entities as could ever share it
// (the least Component_Type.rows of its components) when it is made, so no
// later move reallocates its columns: a pointer to one entity's component stays good while another
// entity spawns into the same archetype, which the sim does mid-step.
ecs_set_components :: proc(e: ^Ecs, id: ecs.EntityID, mask: Component_Mask) {
	w := e.world
	rec := &w.records[u64(id) & ecs.ENTITY_INDEX_MASK]
	from := rec.archetype
	to, found := e.archetypes[mask]
	if !found {
		sig: [MAX_COMPONENTS]ecs.ComponentID
		n := 0
		rows := max(int)
		for c in mask {
			sig[n] = cid_of(c)
			n += 1
			rows = min(rows, catalog[c].rows)
		}
		rows = mask == {} ? 0 : rows
		to = ecs.get_or_create_archetype(w, sig[:n])
		for &col in to.columns {
			reserve(&col.data, rows * col.elem_size)
		}
		e.archetypes[mask] = to
	}
	if to == from {
		return
	}
	col_map: [MAX_COMPONENTS]i16
	for to_col in 0 ..< len(to.columns) {
		col_map[to_col] = -1
	}
	for cid, i in to.signature {
		to_col := to.column_indices[i]
		if to_col >= 0 {
			col_map[to_col] = i16(ecs.archetype_get_column(from, cid))
		}
	}
	ecs.move_entity(w, id, from, to, col_map[:len(to.columns)])
}

// Adds T to entity id with `value`, or sets it if it is already there.
add :: proc(e: ^Ecs, id: ecs.EntityID, value: $T) -> ^T {
	if !has(e, id, T) {
		ecs_set_components(e, id, components_of(e, id) + {component_id(T)})
	}
	p := get(e, id, T)
	p^ = value
	return p
}

remove :: proc(e: ^Ecs, id: ecs.EntityID, $T: typeid) {
	if has(e, id, T) {
		ecs_set_components(e, id, components_of(e, id) - {component_id(T)})
	}
}

// ---------------------------------------------------------------------------
// Snapshots
// ---------------------------------------------------------------------------

// FNV-1a, byte by byte, the same on every machine.
Hasher :: struct {
	sum: u64,
}

hasher :: proc "contextless" () -> Hasher {
	return {0xcbf29ce484222325}
}

hash_bytes :: proc "contextless" (h: ^Hasher, p: rawptr, n: int) {
	b := ([^]u8)(p)
	for i in 0 ..< n {
		h.sum ~= u64(b[i])
		h.sum *= 0x100000001b3
	}
}

hash_u64 :: proc "contextless" (h: ^Hasher, v: u64) {
	x := v
	hash_bytes(h, &x, 8)
}

// Where a world's bytes go: appended to a buffer, or only hashed.
@(private = "file")
Sink :: struct {
	buf:  ^[dynamic]byte,
	hash: ^Hasher,
}

@(private = "file")
sink_write :: proc(s: ^Sink, p: rawptr, n: int) {
	if s.buf != nil {
		append(s.buf, ..([^]u8)(p)[:n])
	} else {
		hash_bytes(s.hash, p, n)
	}
}

@(private = "file")
END_OF_ENTITIES :: ~u32(0)

// The world's state, in an order and form that does not depend on its
// history: for each entity with components, in id order, its id, which
// components it has, and each one's data bytes in id order. What odecs keeps
// on the side -- archetypes, rows, edges, caches -- is not written; reading
// rebuilds it.
@(private = "file")
ecs_emit :: proc(e: ^Ecs, s: ^Sink) {
	header := [2]u64{catalog_hash(), u64(FIXED_ENTITIES)}
	sink_write(s, &header, size_of(header))
	w := e.world
	for i in 1 ..= FIXED_ENTITIES {
		rec := &w.records[i]
		arch := rec.archetype
		if len(arch.signature) == 0 {
			continue
		}
		index := u32(i)
		sink_write(s, &index, 4)
		m: Component_Mask
		for c in arch.signature {
			m += {id_of(c)}
		}
		sink_write(s, &m, size_of(m))
		// The signature is sorted by id, so this is id order.
		for c, k in arch.signature {
			col_i := arch.column_indices[k]
			if col_i < 0 {
				continue
			}
			col := &arch.columns[col_i]
			base := &col.data[rec.row * col.elem_size]
			for r in catalog[id_of(c)].runs {
				sink_write(s, rawptr(uintptr(base) + uintptr(r.offset)), int(r.size))
			}
		}
	}
	end := END_OF_ENTITIES
	sink_write(s, &end, 4)
}

// Appends the world's state to buf.
ecs_write :: proc(e: ^Ecs, buf: ^[dynamic]byte) {
	s := Sink{buf = buf}
	ecs_emit(e, &s)
}

// Mixes the world's state into h: the same bytes ecs_write would write.
ecs_hash :: proc(e: ^Ecs, h: ^Hasher) {
	s := Sink{hash = h}
	ecs_emit(e, &s)
}

// Makes the world hold what `data` (from ecs_write) holds, and returns the
// bytes after it. Fails, leaving the world unchanged, if the data came from
// a build with a different catalog or is cut short.
ecs_read :: proc(e: ^Ecs, data: []byte) -> (rest: []byte, ok: bool) {
	// Check it all first, so a bad snapshot changes nothing.
	end, valid := ecs_scan(data)
	if !valid {
		return data, false
	}
	at := 16
	next := 1
	take :: proc(data: []byte, at: ^int, $T: typeid) -> T {
		v: T
		runtime.mem_copy_non_overlapping(&v, &data[at^], size_of(T))
		at^ += size_of(T)
		return v
	}
	for {
		index := take(data, &at, u32)
		limit := index == END_OF_ENTITIES ? FIXED_ENTITIES + 1 : int(index)
		for ; next < limit; next += 1 {
			ecs_set_components(e, ecs.EntityID(next), {})
		}
		if index == END_OF_ENTITIES {
			break
		}
		id := ecs.EntityID(index)
		mask := take(data, &at, Component_Mask)
		ecs_set_components(e, id, mask)
		rec := &e.world.records[index]
		arch := rec.archetype
		for c, k in arch.signature {
			col_i := arch.column_indices[k]
			if col_i < 0 {
				continue
			}
			col := &arch.columns[col_i]
			base := &col.data[rec.row * col.elem_size]
			for r in catalog[id_of(c)].runs {
				runtime.mem_copy_non_overlapping(rawptr(uintptr(base) + uintptr(r.offset)), &data[at], int(r.size))
				at += int(r.size)
			}
		}
		next = int(index) + 1
	}
	return data[end:], true
}

// Walks data as ecs_read would, without changing anything, and returns
// where it ends.
@(private = "file")
ecs_scan :: proc(data: []byte) -> (end: int, ok: bool) {
	if len(data) < 16 {
		return
	}
	header: [2]u64
	runtime.mem_copy_non_overlapping(&header, &data[0], 16)
	if header[0] != catalog_hash() || header[1] != u64(FIXED_ENTITIES) {
		return
	}
	at := 16
	last := 0
	for {
		if at + 4 > len(data) {
			return
		}
		index: u32
		runtime.mem_copy_non_overlapping(&index, &data[at], 4)
		at += 4
		if index == END_OF_ENTITIES {
			return at, true
		}
		if int(index) <= last || int(index) > FIXED_ENTITIES || at + size_of(Component_Mask) > len(data) {
			return
		}
		last = int(index)
		mask: Component_Mask
		runtime.mem_copy_non_overlapping(&mask, &data[at], size_of(mask))
		at += size_of(mask)
		for c in mask {
			if c >= catalog_count {
				return
			}
			for r in catalog[c].runs {
				at += int(r.size)
			}
		}
		if at > len(data) {
			return
		}
	}
}
