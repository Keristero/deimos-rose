package tests

import "base:runtime"
import "core:log"
import vmem "core:mem/virtual"
import "core:os"
import "core:testing"

import "dr:data"
import "dr:plugins/fps_unlock"
import "dr:sim"
import "dr:sim/lifecycle"
import "dr:sim/systems/entity_system"

// Component queries (docs/phase-9-ecs.md, D45): a stage runs for the
// entities whose components, their own and their unit's and state's,
// match it, so a plugin can give any unit a core behaviour, and an entity's
// own component overrides its prefabs'. The test builders and stages here
// belong to 30FPS Unlock, which no real session carries (it is not a
// session plugin), so they reach only the sessions below, which name it.

Test_Mark :: struct {
	v: i32,
}

Test_Player_Tag :: struct {}

@(private = "file")
MINE :: sim.Res_ID{'m', 'i', 'n', 'e'}

@(private = "file")
player_stage_runs: [sim.MAX_PLAYERS]int

@(init)
register_query_tests :: proc "contextless" () {
	context = runtime.default_context()
	sim.prefab_component_register(Test_Mark)
	sim.component_register(Test_Player_Tag, sim.MAX_PLAYERS)
	sim.prefab_builder_register({
		name = "test_queries",
		plugin = fps_unlock.ID,
		build = proc(p: sim.Prefab, u: ^sim.Unit, st: ^sim.Unit_State) {
			if u.id != MINE {
				return
			}
			if st == nil {
				sim.prefab_add(p, Test_Mark{1})
				return
			}
			// The mine holds the scroll, as a state that pauses it does.
			sim.prefab_add(p, entity_system.Pauses_Scrolling{})
			sim.prefab_add(p, Test_Mark{2})
		},
	})
	sim.player_stage_register({
		name = "test_tagged_players",
		plugin = fps_unlock.ID,
		with = sim.mask_of(Test_Player_Tag),
		run = proc(s: ^sim.State, p: sim.Player, ps: ^sim.Player_Step) -> bool {
			player_stage_runs[p.number] += 1
			return true
		},
	})
}

@(private = "file")
Query_Fixture :: struct {
	arena: vmem.Arena,
	defs:  sim.Defs,
	s:     ^sim.State,
}

// Stage 1 once the ship is in play, with or without the test builders.
@(private = "file")
query_fixture :: proc(t: ^testing.T, f: ^Query_Fixture, builders: bool) -> bool {
	if !os.exists("assets/data/index.json") {
		log.info("skipped: needs the extracted assets tree")
		return false
	}
	testing.expect(t, vmem.arena_init_growing(&f.arena) == nil)
	alloc := vmem.arena_allocator(&f.arena)
	f.defs, _ = data.assets_defs_load("assets", alloc)
	f.s = new(sim.State, alloc)
	context.allocator = alloc
	mods := builders ? sim.Mods{int(fps_unlock.ID)} : {}
	sim.init(f.s, sim.Session{seed = 1, level_id = f.defs.levels[0].id, game_type = .Single, mods = mods}, &f.defs)
	for i := 0; i < 300 && sim.player_at(f.s, 0).state != .Playing; i += 1 {
		sim.session_step(f.s, {})
	}
	return testing.expect(t, sim.player_at(f.s, 0).state == .Playing, "the ship must be in play")
}

@(private = "file")
spawn_mine :: proc(t: ^testing.T, s: ^sim.State) -> (sim.Entity, bool) {
	req := sim.spawn_request(MINE)
	req.loc = {200, 100}
	req.stationary = true
	r := lifecycle.eg_request_spawn(s, req)
	if !testing.expect(t, sim.ref_valid(s, r), "the mine must spawn") {
		return {}, false
	}
	e := sim.entity_at(s, r.index)
	e.appear_delay = 0
	return e, true
}

@(test)
a_plugins_builder_gives_a_unit_a_core_behaviour :: proc(t: ^testing.T) {
	for builders in ([2]bool{false, true}) {
		f: Query_Fixture
		defer vmem.arena_destroy(&f.arena)
		if !query_fixture(t, &f, builders) {
			return
		}
		if _, ok := spawn_mine(t, f.s); !ok {
			return
		}
		sim.session_step(f.s, {})
		sim.session_step(f.s, {})
		// A mine never holds the scroll itself; with the builder, every one
		// of its states has Pauses_Scrolling, and the scroll stops.
		held := sim.single(f.s, sim.Bgnd).speed == 0
		testing.expectf(t, held == builders, "with the builder %v, the scroll held %v", builders, held)
	}
}

@(test)
an_entitys_own_component_overrides_its_prefabs :: proc(t: ^testing.T) {
	f: Query_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !query_fixture(t, &f, true) {
		return
	}
	e, ok := spawn_mine(t, f.s)
	if !ok {
		return
	}
	// The state's prefab over the unit's.
	testing.expect_value(t, sim.entity_component(f.s, e, Test_Mark).v, i32(2))
	es := sim.entity_step(f.s, e, 0)
	testing.expect_value(t, sim.step_component(f.s, e, &es, Test_Mark).v, i32(2))
	testing.expect(t, sim.step_has(&es, entity_system.Pauses_Scrolling))
	testing.expect(t, sim.entity_has(f.s, e, entity_system.Pauses_Scrolling))
	testing.expect(t, !sim.entity_has(f.s, e, entity_system.Motion_Blur))

	// The entity's own over both. Giving it a component moves its row, and
	// the row moved into the gap it leaves, so any view into that table --
	// its own and other entities' -- is found again from its index, not
	// read through the old one.
	index := e.pool_index
	sim.add(f.s.ecs, sim.pool_entity(index), Test_Mark{3})
	e = sim.entity_at(f.s, index)
	testing.expect_value(t, sim.entity_component(f.s, e, Test_Mark).v, i32(3))
	es = sim.entity_step(f.s, e, 0)
	testing.expect_value(t, sim.step_component(f.s, e, &es, Test_Mark).v, i32(3))
	sim.remove(f.s.ecs, sim.pool_entity(index), Test_Mark)
	e = sim.entity_at(f.s, index)
	testing.expect_value(t, sim.entity_component(f.s, e, Test_Mark).v, i32(2))
}

@(test)
a_player_stage_runs_for_the_players_that_match_it :: proc(t: ^testing.T) {
	f: Query_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !query_fixture(t, &f, true) {
		return
	}
	player_stage_runs = {}
	sim.session_step(f.s, {})
	testing.expect_value(t, player_stage_runs, [sim.MAX_PLAYERS]int{})
	sim.add(f.s.ecs, sim.player_entity(0), Test_Player_Tag{})
	sim.session_step(f.s, {})
	testing.expect_value(t, player_stage_runs[0], 1)
	testing.expect_value(t, player_stage_runs[1], 0)
}
