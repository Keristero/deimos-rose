package tests

import "base:runtime"
import "core:testing"

import "dr:plugins/fps_unlock"
import "dr:sim"
import _ "dr:sim/core"
import "dr:sim/systems/entity_system"

// Prefabs (sim/prefabs.odin): a unit's states become prefab entities whose
// components follow the definitions' flags, and a plugin's builder runs only
// in a session with that plugin on.

Test_Prefab_Tag :: struct {}

@(init)
register_test_prefab :: proc "contextless" () {
	context = runtime.default_context()
	sim.prefab_component_register(Test_Prefab_Tag)
	sim.prefab_builder_register({
		name = "test_prefab",
		plugin = fps_unlock.ID,
		build = proc(p: sim.Prefab, u: ^sim.Unit, st: ^sim.Unit_State) {
			if st == nil {
				sim.prefab_add(p, Test_Prefab_Tag{})
			}
		},
	})
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

	testing.expect_value(t, sim.prefab_state_mask(&pf, 0, 0), sim.mask_of(entity_system.Emits_Particles, entity_system.Follows_Rules))
	testing.expect_value(t, sim.prefab_state_mask(&pf, 0, 1), sim.Component_Mask{})
	testing.expect_value(t, sim.prefab_state_mask(&pf, 0, 2), sim.mask_of(entity_system.Pauses_Scrolling, entity_system.Motion_Blur))
	testing.expect_value(t, sim.prefab_state_mask(&pf, 1, 0), sim.mask_of(entity_system.Follows_Owner_Look))
	testing.expect_value(t, pf.unit_mask[0], sim.Component_Mask{})

	p := sim.get(pf.world, sim.prefab_state_id(&pf, 0, 0), entity_system.Emits_Particles)
	testing.expect(t, p != nil)
	testing.expect_value(t, p.particles, sim.Res_ID{1, 2, 3, 4})
	testing.expect_value(t, p.repeat_delay, i32(7))
	b := sim.get(pf.world, sim.prefab_state_id(&pf, 0, 2), entity_system.Motion_Blur)
	testing.expect_value(t, b.min_gap, i32(3))
	look := sim.get(pf.world, sim.prefab_state_id(&pf, 1, 0), entity_system.Follows_Owner_Look)
	testing.expect_value(t, look^, entity_system.Follows_Owner_Look{scale = true})
}

@(test)
prefab_builders_follow_the_session_plugins :: proc(t: ^testing.T) {
	defs := prefab_defs()
	defer prefab_defs_free(&defs)
	pf: sim.Prefabs
	defer sim.prefabs_destroy(&pf)

	sim.prefabs_build(&pf, &defs, {})
	testing.expect(t, !sim.has(pf.world, sim.prefab_unit_id(1), Test_Prefab_Tag))

	// A rebuild with the plugin on reuses pf and gives every unit the tag.
	sim.prefabs_build(&pf, &defs, {int(fps_unlock.ID)})
	testing.expect_value(t, pf.unit_mask[1], sim.mask_of(Test_Prefab_Tag))
	testing.expect_value(t, sim.prefab_state_mask(&pf, 1, 0), sim.mask_of(entity_system.Follows_Owner_Look))
}
