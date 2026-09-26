package sim

import "base:runtime"
import ecs "dr:third_party/odecs"

// Prefabs: what every entity in one state of a unit shares, as components
// (notes/ecs-refactor.md, D47).
//
// The original chooses an entity's behaviour by flags in its unit and state
// definitions, read inside long procedures: "if the state orbits its owner,
// orbit". Here those flags are components. Each state of each unit is a
// prefab entity, in a world of its own, carrying the components its unit's
// flags and its own flags turn on, with the parameters the behaviour needs.
// An entity inherits its state's prefab, as a flecs instance inherits
// through IsA: changing state changes which systems it takes part in, and
// no row of the entity's own moves. A plugin can add its own components to
// any prefab, and reuse the core's.
//
// The components come from builders (prefab_builder_register), which read
// the definitions: each system's package registers the builders for the
// components its systems ask for. They run when a session starts, with that
// session's plugins, so a prefab never holds a component nothing in the
// session reads.
//
// A system asks for prefabs by query (prefab_query_register): the
// components a prefab must have and must not. Each query is run over the
// prefab world with odecs's query_raw once, as the prefabs are built, and
// each prefab keeps the set of queries it matches, so a step asks a bit and
// not the world.
//
// Prefabs are derived from the definitions, which never change in a
// session, so they are not state: snapshots leave them out, as they leave
// out `defs`, and a state read from elsewhere builds its own.

MAX_PREFAB_BUILDERS :: 64
MAX_PREFAB_QUERIES :: 128

// On every prefab entity: what every prefab query starts from, since odecs
// finds nothing for a query of no components.
Is_Prefab :: struct {}

// A registered query, by index.
Prefab_Query :: distinct u8

// The queries a prefab matches.
Query_Set :: bit_set[0 ..< MAX_PREFAB_QUERIES; u128]

Prefabs :: struct {
	world:       ^ecs.World,
	defs:        ^Defs,
	mods:        Mods,
	// State k of unit u is prefab first_state[u] + k.
	first_state: []i32,
	ids:         []ecs.EntityID,
	matches:     []Query_Set,
	allocator:   runtime.Allocator,
}

// Where a builder puts the components it makes.
Prefab :: struct {
	world: ^ecs.World,
	id:    ecs.EntityID,
}

// Makes components for the prefab of state `st` of unit `u` from their
// definitions: the unit's, then the state's, so that where both give a
// component the state's value is the one kept.
Prefab_Builder :: struct {
	name:   string,
	plugin: Plugin_ID, // runs only in a session with this plugin on
	build:  proc(p: Prefab, u: ^Unit, st: ^Unit_State),
}

@(private = "file")
builders: [MAX_PREFAB_BUILDERS]Prefab_Builder
@(private = "file")
builder_count: int

@(private = "file")
Query_Terms :: struct {
	with, without: []typeid,
}

@(private = "file")
queries: [MAX_PREFAB_QUERIES]Query_Terms
@(private = "file")
query_count: int
@(private = "file")
term_pool: [512]typeid
@(private = "file")
term_used: int

@(init)
register_prefab_marker :: proc "contextless" () {
	context = runtime.default_context()
	component_register(Is_Prefab)
}

// Called from `@(init)` procedures only, like system_register.
prefab_builder_register :: proc(b: Prefab_Builder) {
	assert(builder_count < MAX_PREFAB_BUILDERS, "sim: too many prefab builders")
	builders[builder_count] = b
	builder_count += 1
}

// The prefabs that have every component in `with` and none in `without`.
// Called from `@(init)` procedures only; the lists are copied.
prefab_query_register :: proc(with: []typeid, without: []typeid = nil) -> Prefab_Query {
	assert(query_count < MAX_PREFAB_QUERIES, "sim: too many prefab queries")
	keep :: proc(types: []typeid) -> []typeid {
		assert(term_used + len(types) <= len(term_pool), "sim: too many prefab query terms")
		kept := term_pool[term_used:][:len(types)]
		copy(kept, types)
		term_used += len(types)
		return kept
	}
	queries[query_count] = {keep(with), keep(without)}
	query_count += 1
	return Prefab_Query(query_count - 1)
}

// Gives the prefab component T, holding `value`. T must be in the catalog
// (component_register).
prefab_add :: proc(p: Prefab, value: $T) {
	assert(component_id(T) >= 0, "sim: a prefab component must be registered")
	ecs.add_component(p.world, p.id, value)
}

// Builds the prefabs for defs and a session's plugins, reusing pf's memory
// where it has any.
prefabs_build :: proc(pf: ^Prefabs, defs: ^Defs, mods: Mods, allocator := context.allocator) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	prefabs_destroy(pf)
	pf.allocator = allocator
	pf.defs = defs
	pf.mods = mods
	pf.first_state = make([]i32, len(defs.units), allocator)
	total := 0
	for &u, i in defs.units {
		pf.first_state[i] = i32(total)
		total += len(u.states)
	}
	pf.world = ecs.create_world(allocator, allocator)
	w := pf.world
	for c in component_types() {
		c.register(w)
	}
	pf.ids = make([]ecs.EntityID, total, allocator)
	index := make(map[ecs.EntityID]int, total, context.temp_allocator)
	for &u, i in defs.units {
		for &st, k in u.states {
			at := int(pf.first_state[i]) + k
			pf.ids[at] = ecs.add_entity(w, Is_Prefab{})
			index[pf.ids[at]] = at
			for b in builders[:builder_count] {
				if b.plugin == CORE || int(b.plugin) in mods {
					b.build({w, pf.ids[at]}, &u, &st)
				}
			}
		}
	}
	// Each query, once: the archetypes with its components, less those with
	// any it must not have.
	pf.matches = make([]Query_Set, total, allocator)
	terms := make([dynamic]typeid, context.temp_allocator)
	for q, qi in queries[:query_count] {
		clear(&terms)
		append(&terms, Is_Prefab)
		append(&terms, ..q.with)
		found: for arch in ecs.query_raw(w, terms[:]) {
			for t in q.without {
				for other in ecs.query_raw(w, {Is_Prefab, t}) {
					if other == arch {
						continue found
					}
				}
			}
			for id in ecs.get_entities(arch) {
				pf.matches[index[id]] += {qi}
			}
		}
	}
}

prefabs_destroy :: proc(pf: ^Prefabs) {
	if pf.world == nil {
		return
	}
	ecs.delete_world(pf.world)
	delete(pf.first_state, pf.allocator)
	delete(pf.ids, pf.allocator)
	delete(pf.matches, pf.allocator)
	pf^ = {}
}

// Makes s's prefabs match its definitions and plugins, building them if
// they do not: after init, and after a state is read in from elsewhere.
prefabs_ensure :: proc(s: ^State) {
	pf := s.prefabs
	if pf == nil {
		pf = new(Prefabs)
		s.prefabs = pf
	}
	if pf.world == nil || pf.defs != s.defs || pf.mods != s.session.mods {
		prefabs_build(pf, s.defs, s.session.mods)
	}
}

// The prefab of state `state` of unit `unit`.
prefab_at :: #force_inline proc "contextless" (s: ^State, unit, state: i32) -> i32 {
	assert_contextless(state >= 0, "sim: an entity in no state has no prefab")
	return s.prefabs.first_state[unit] + state
}

// The prefab an entity inherits now, in its current state.
prefab_of :: #force_inline proc "contextless" (s: ^State, e: Entity) -> i32 {
	return prefab_at(s, e.unit, e.state)
}

// Whether a prefab is one that query `q` finds.
prefab_is :: #force_inline proc "contextless" (s: ^State, prefab: i32, q: Prefab_Query) -> bool {
	return int(q) in s.prefabs.matches[prefab]
}

// A prefab's T: nil when it has none, and for a tag, which has nothing to
// point at (prefab_has).
prefab_component :: proc(s: ^State, prefab: i32, $T: typeid) -> ^T {
	return ecs.get_component(s.prefabs.world, s.prefabs.ids[prefab], T)
}

prefab_has :: proc(s: ^State, prefab: i32, $T: typeid) -> bool {
	return ecs.has_component(s.prefabs.world, s.prefabs.ids[prefab], T)
}
