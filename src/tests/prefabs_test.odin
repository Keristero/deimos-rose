package tests

import "base:runtime"
import "core:testing"

import "dr:plugins/fps_unlock"
import "dr:sim"
import _ "dr:sim/core"
import "dr:sim/systems/entity_system"
import "dr:sim/systems/movement_system"
import ecs "dr:third_party/odecs"

// Prefabs (sim/prefabs.odin): each state of a unit becomes a prefab entity
// whose components follow its unit's and its own flags, a plugin's builder
// runs only in a session with that plugin on, and a query finds the
// prefabs with the components it asks for and without those it rules out.

Test_Prefab_Tag :: struct {}

@(private = "file")
particles_without_rules: sim.Prefab_Query

@(init)
register_test_prefab :: proc "contextless" () {
	context = runtime.default_context()
	sim.component_register(Test_Prefab_Tag)
	sim.prefab_builder_register({
		name = "test_prefab",
		plugin = fps_unlock.ID,
		build = proc(p: sim.Prefab, u: ^sim.Unit, st: ^sim.Unit_State) {
			sim.prefab_add(p, Test_Prefab_Tag{})
		},
	})
	particles_without_rules = sim.prefab_query_register({entity_system.Emits_Particles}, {entity_system.Follows_Rules})
}

// Whether the prefab of state k of unit u has T.
@(private = "file")
holds :: proc(pf: ^sim.Prefabs, u, k: i32, $T: typeid) -> bool {
	return ecs.has_component(pf.world, pf.ids[pf.first_state[u] + k], T)
}

@(private = "file")
component_of :: proc(pf: ^sim.Prefabs, u, k: i32, $T: typeid) -> ^T {
	return ecs.get_component(pf.world, pf.ids[pf.first_state[u] + k], T)
}

@(private = "file")
prefab_defs :: proc() -> (defs: sim.Defs) {
	a := make([]sim.Unit_State, 3)
	b := make([]sim.Unit_State, 1)
	// Loaded definitions hold NONE for an unset resource, not zero.
	for &st in a {
		st.particles, st.entry_sound = sim.NONE, sim.NONE
	}
	b[0].particles, b[0].entry_sound = sim.NONE, sim.NONE
	a[0].particles = {1, 2, 3, 4}
	a[0].particles_repeat_delay = 7
	a[0].rules = make([]sim.Rule, 1)
	a[2].pause_vertical_scrolling = true
	a[2].motion_blur_required = true
	a[2].motion_blur_min_time_between_blurs = 3
	b[0].use_owners_scale = true
	defs.units = make([]sim.Unit, 2)
	defs.units[0].states = a
	defs.units[1].states = b
	defs.units[1].flees_north_on_no_active_players = true
	defs.units[1].flees_south_on_no_active_players = true
	defs.units[1].constrain_in_game_area = true
	return
}

@(private = "file")
prefab_defs_free :: proc(defs: ^sim.Defs) {
	delete(defs.units[0].states[0].rules)
	for u in defs.units {
		delete(u.states)
	}
	delete(defs.units)
}

@(test)
prefabs_follow_the_state_flags :: proc(t: ^testing.T) {
	defs := prefab_defs()
	defer prefab_defs_free(&defs)
	pf: sim.Prefabs
	sim.prefabs_build(&pf, &defs, {})
	defer sim.prefabs_destroy(&pf)

	testing.expect(t, holds(&pf, 0, 0, entity_system.Emits_Particles))
	testing.expect(t, holds(&pf, 0, 0, entity_system.Follows_Rules))
	testing.expect(t, !holds(&pf, 0, 0, entity_system.Pauses_Scrolling))
	for k in i32(0) ..< 3 {
		testing.expect(t, !holds(&pf, 0, k, movement_system.Flees_Without_Players), "unit 0 flees from nothing")
	}
	testing.expect(t, !holds(&pf, 0, 1, entity_system.Emits_Particles))
	testing.expect(t, !holds(&pf, 0, 1, entity_system.Follows_Rules))
	testing.expect(t, holds(&pf, 0, 2, entity_system.Pauses_Scrolling))
	testing.expect(t, holds(&pf, 0, 2, entity_system.Motion_Blur))
	// A state carries its unit's components as well as its own.
	testing.expect(t, holds(&pf, 1, 0, entity_system.Follows_Owner_Look))
	testing.expect(t, holds(&pf, 1, 0, movement_system.Flees_Without_Players))
	testing.expect(t, holds(&pf, 1, 0, movement_system.Constrained_To_Play_Area))

	p := component_of(&pf, 0, 0, entity_system.Emits_Particles)
	testing.expect(t, p != nil)
	testing.expect_value(t, p.particles, sim.Res_ID{1, 2, 3, 4})
	testing.expect_value(t, p.repeat_delay, i32(7))
	b := component_of(&pf, 0, 2, entity_system.Motion_Blur)
	testing.expect_value(t, b.min_gap, i32(3))
	look := component_of(&pf, 1, 0, entity_system.Follows_Owner_Look)
	testing.expect_value(t, look^, entity_system.Follows_Owner_Look{scale = true})
	// North wins where a unit sets both, as in the original's test order.
	flee := component_of(&pf, 1, 0, movement_system.Flees_Without_Players)
	testing.expect_value(t, flee.flee, sim.res_id("nora"))

	// Particles but no rules: state 0 of unit 0 has both, so only the
	// states with particles alone would match, and there are none.
	for m in pf.matches {
		testing.expect(t, int(particles_without_rules) not_in m)
	}
}

// A query's `without` rules out only the prefabs that have what it names.
@(test)
a_query_rules_out_what_it_names :: proc(t: ^testing.T) {
	defs := prefab_defs()
	defer prefab_defs_free(&defs)
	rules := defs.units[0].states[0].rules
	defs.units[0].states[0].rules = nil
	defer defs.units[0].states[0].rules = rules
	pf: sim.Prefabs
	sim.prefabs_build(&pf, &defs, {})
	defer sim.prefabs_destroy(&pf)
	testing.expect(t, int(particles_without_rules) in pf.matches[pf.first_state[0]])
	testing.expect(t, int(particles_without_rules) not_in pf.matches[pf.first_state[0] + 1])
}

@(test)
prefab_builders_follow_the_session_plugins :: proc(t: ^testing.T) {
	defs := prefab_defs()
	defer prefab_defs_free(&defs)
	pf: sim.Prefabs
	defer sim.prefabs_destroy(&pf)

	sim.prefabs_build(&pf, &defs, {})
	testing.expect(t, !holds(&pf, 1, 0, Test_Prefab_Tag))

	// A rebuild with the plugin on reuses pf and gives every state the tag.
	sim.prefabs_build(&pf, &defs, {int(fps_unlock.ID)})
	testing.expect(t, holds(&pf, 1, 0, Test_Prefab_Tag))
	testing.expect(t, holds(&pf, 0, 2, Test_Prefab_Tag))
	testing.expect(t, holds(&pf, 1, 0, entity_system.Follows_Owner_Look))
}
