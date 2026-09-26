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
	world:       ^Ecs,
	defs:        ^Defs,
	mods:        Mods,
	// Prefab entity of unit u is u + 1; the prefab of state k of unit u is
	// first_state[u] + k.
	first_state: []i32,
	unit_mask:   []Component_Mask,
	state_mask:  []Component_Mask,
	allocator:   runtime.Allocator,
}

// Where a builder puts the components it makes.
Prefab :: struct {
	world: ^Ecs,
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

// Gives the prefab component T, holding `value`.
prefab_add :: proc(p: Prefab, value: $T) {
	add(p.world, p.id, value)
}

// Builds the prefabs for defs and a session's plugins, reusing pf's memory
// where it has any.
prefabs_build :: proc(pf: ^Prefabs, defs: ^Defs, mods: Mods, allocator := context.allocator) {
	prefabs_destroy(pf)
	pf.allocator = allocator
	pf.defs = defs
	pf.mods = mods
	n := len(defs.units)
	pf.first_state = make([]i32, n, allocator)
	total := n
	for &u, i in defs.units {
		pf.first_state[i] = i32(total + 1)
		total += len(u.states)
	}
	pf.world = ecs_create(allocator, total)
	pf.unit_mask = make([]Component_Mask, n, allocator)
	pf.state_mask = make([]Component_Mask, total - n, allocator)
	for &u, i in defs.units {
		unit := Prefab{pf.world, ecs.EntityID(i + 1)}
		for b in builders[:builder_count] {
			if b.plugin == CORE || int(b.plugin) in mods {
				b.build(unit, &u, nil)
			}
		}
		pf.unit_mask[i] = components_of(pf.world, unit.id)
		for &st, k in u.states {
			state := Prefab{pf.world, ecs.EntityID(int(pf.first_state[i]) + k)}
			for b in builders[:builder_count] {
				if b.plugin == CORE || int(b.plugin) in mods {
					b.build(state, &u, &st)
				}
			}
			pf.state_mask[int(pf.first_state[i]) - n - 1 + k] = components_of(pf.world, state.id)
		}
	}
}

prefabs_destroy :: proc(pf: ^Prefabs) {
	if pf.world == nil {
		return
	}
	ecs_destroy(pf.world)
	delete(pf.first_state, pf.allocator)
	delete(pf.unit_mask, pf.allocator)
	delete(pf.state_mask, pf.allocator)
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

prefab_unit_id :: #force_inline proc "contextless" (unit: i32) -> ecs.EntityID {
	return ecs.EntityID(unit + 1)
}

prefab_state_id :: #force_inline proc "contextless" (pf: ^Prefabs, unit, state: i32) -> ecs.EntityID {
	return ecs.EntityID(pf.first_state[unit] + state)
}

prefab_state_mask :: #force_inline proc "contextless" (pf: ^Prefabs, unit, state: i32) -> Component_Mask {
	return pf.state_mask[int(pf.first_state[unit]) - len(pf.unit_mask) - 1 + int(state)]
}
