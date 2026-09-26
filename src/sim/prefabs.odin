package sim

import "base:runtime"
import ecs "dr:third_party/odecs"

// Prefabs: what every entity of a unit shares, and what every entity in one
// of its states shares, as components (notes/ecs-refactor.md).
//
// The original chooses an entity's behaviour by flags in its unit and state
// definitions, read inside long procedures: "if the state orbits its owner,
// orbit". Here those flags are components. Each unit is a prefab entity,
// and so is each of its states, in a world of their own. What a flag turned
// on is a component the prefab carries, holding the parameters the
// behaviour needs, and a system that needs it asks for it by its query. So
// an entity has the components of its unit and of the state it is in as
// well as its own; changing state changes which systems it takes part in.
// A plugin can add its own components to any prefab, and reuse the core's.
//
// The components come from builders (prefab_builder_register), which read
// the definitions: each system's package registers the builders for the
// components its systems ask for. They run when a session starts, with that
// session's plugins, so a prefab never holds a component nothing in the
// session reads.
//
// Prefabs are derived from the definitions, which never change in a
// session, so they are not state: snapshots leave them out, as they leave
// out `defs`, and a state read from elsewhere builds its own.
//
// Sharing, not copying, is what lets an entity change state mid-step: its
// own components never move, so no system's view of another entity goes
// stale (odecs moves rows when an entity's components change, D39).

MAX_PREFAB_BUILDERS :: 64

Prefabs :: struct {
	world:       ^ecs.World,
	defs:        ^Defs,
	mods:        Mods,
	// Unit u's prefab is ids[u]; state k of unit u's is ids[first_state[u] + k].
	ids:         []ecs.EntityID,
	first_state: []i32,
	unit_mask:   []Component_Mask,
	state_mask:  []Component_Mask,
	allocator:   runtime.Allocator,
}

// Where a builder puts the components it makes.
Prefab :: struct {
	world: ^ecs.World,
	id:    ecs.EntityID,
}

// Makes components for a prefab from its definitions: for a unit's own
// prefab `st` is nil; for one of its states it is that state.
Prefab_Builder :: struct {
	name:   string,
	plugin: Plugin_ID, // runs only in a session with this plugin on
	build:  proc(p: Prefab, u: ^Unit, st: ^Unit_State),
}

@(private = "file")
builders: [MAX_PREFAB_BUILDERS]Prefab_Builder
@(private = "file")
builder_count: int

// Called from `@(init)` procedures only, like system_register.
prefab_builder_register :: proc(b: Prefab_Builder) {
	assert(builder_count < MAX_PREFAB_BUILDERS, "sim: too many prefab builders")
	builders[builder_count] = b
	builder_count += 1
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
	n := len(defs.units)
	pf.first_state = make([]i32, n, allocator)
	total := n
	for &u, i in defs.units {
		pf.first_state[i] = i32(total)
		total += len(u.states)
	}
	pf.world = ecs.create_world(allocator, allocator)
	for c in component_types() {
		c.register(pf.world)
	}
	pf.ids = make([]ecs.EntityID, total, allocator)
	index := make(map[ecs.EntityID]int, total, context.temp_allocator)
	for &id, i in pf.ids {
		id = ecs.add_entity(pf.world)
		index[id] = i
	}
	for &u, i in defs.units {
		for b in builders[:builder_count] {
			if b.plugin == CORE || int(b.plugin) in mods {
				b.build({pf.world, pf.ids[i]}, &u, nil)
			}
		}
		for &st, k in u.states {
			for b in builders[:builder_count] {
				if b.plugin == CORE || int(b.plugin) in mods {
					b.build({pf.world, pf.ids[int(pf.first_state[i]) + k]}, &u, &st)
				}
			}
		}
	}
	// Each prefab's components, from the world: which prefabs hold each one.
	masks := make([]Component_Mask, total, allocator)
	for c, ci in component_types() {
		for arch in ecs.query_raw(pf.world, {c.type}) {
			for id in ecs.get_entities(arch) {
				masks[index[id]] += {ci}
			}
		}
	}
	pf.unit_mask = masks[:n]
	pf.state_mask = masks[n:]
}

prefabs_destroy :: proc(pf: ^Prefabs) {
	if pf.world == nil {
		return
	}
	ecs.delete_world(pf.world)
	delete(pf.ids, pf.allocator)
	delete(pf.first_state, pf.allocator)
	delete(raw_data(pf.unit_mask)[:len(pf.unit_mask) + len(pf.state_mask)], pf.allocator)
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

prefab_unit_id :: #force_inline proc "contextless" (pf: ^Prefabs, unit: i32) -> ecs.EntityID {
	return pf.ids[unit]
}

prefab_state_id :: #force_inline proc "contextless" (pf: ^Prefabs, unit, state: i32) -> ecs.EntityID {
	return pf.ids[pf.first_state[unit] + state]
}

prefab_state_mask :: #force_inline proc "contextless" (pf: ^Prefabs, unit, state: i32) -> Component_Mask {
	return pf.state_mask[int(pf.first_state[unit]) - len(pf.unit_mask) + int(state)]
}

// T for the entity as the stage sees it: its state's (the state `es`
// holds), else its unit's. nil when neither has one, and for a tag, which
// has nothing to point at (step_has).
step_component :: proc(s: ^State, e: Entity, es: ^Entity_Step, $T: typeid) -> ^T {
	pf := s.prefabs
	if c := ecs.get_component(pf.world, prefab_state_id(pf, e.unit, es.state), T); c != nil {
		return c
	}
	return ecs.get_component(pf.world, prefab_unit_id(pf, e.unit), T)
}
