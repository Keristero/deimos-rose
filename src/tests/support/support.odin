package test_support

// What every test package shares: loading the shipped content, starting
// play and placing targets. The main suite (tests/) and each plugin's own
// tests (plugins/<name>/tests, which own the tests of what that plugin
// adds) import it. Each package keeps its own `@(init)`, which runs
// sim.register_all.

import "core:log"
import vmem "core:mem/virtual"
import "core:os"
import "core:testing"

import "dr:data"
import "dr:sim"
import "dr:sim/lifecycle"

// For a test of the original's content: the extracted assets' definitions,
// loaded into `arena`, which the caller destroys once it is true. False,
// logged as skipped, without the assets tree or without `needs`, a file or
// folder the test needs besides (a plugin's content, say). The arena is
// the context's allocator while they load, so nothing of theirs is left
// on the test's.
assets_defs :: proc(t: ^testing.T, arena: ^vmem.Arena, needs := "") -> (defs: sim.Defs, ok: bool) {
	if !os.exists("assets/data/index.json") || (needs != "" && !os.exists(needs)) {
		log.infof("skipped: needs the extracted assets tree%s%s", needs != "" ? " and " : "", needs)
		return
	}
	testing.expect(t, vmem.arena_init_growing(arena) == nil)
	context.allocator = vmem.arena_allocator(arena)
	defs, _ = data.assets_defs_load("assets", context.allocator)
	return defs, true
}

// assets_defs with every plugin's content added (data.extra_defs_load), as
// the game loads it. False, the test failed, if that content did not load;
// the arena is then destroyed already.
content_defs :: proc(t: ^testing.T, arena: ^vmem.Arena, needs := "") -> (defs: sim.Defs, ok: bool) {
	defs = assets_defs(t, arena, needs) or_return
	if _, loaded := data.extra_defs_load(&defs, vmem.arena_allocator(arena)); !testing.expect(t, loaded, "the plugins' content must load") {
		vmem.arena_destroy(arena)
		return {}, false
	}
	return defs, true
}

// The index of the weapon `id` in `defs`; sim.NO_WEAPON, the test failed,
// if there is none.
weapon_index :: proc(t: ^testing.T, defs: ^sim.Defs, id: sim.Res_ID) -> i32 {
	for &w, i in defs.weapons {
		if w.id == id {
			return i32(i)
		}
	}
	name := id
	testing.expectf(t, false, "no weapon %s in the data", string(name[:]))
	return sim.NO_WEAPON
}

// Starts `session` on `s` and steps it until player `player`'s ship is in
// play, where most tests of play begin. False, the test failed, if it is
// not in play within 300 steps.
play_start :: proc(t: ^testing.T, s: ^sim.State, session: sim.Session, defs: ^sim.Defs, player := 0, events: ^sim.Event_Log = nil) -> bool {
	sim.init(s, session, defs, events = events)
	for i := 0; i < 300 && sim.player_at(s, player).state != .Playing; i += 1 {
		sim.session_step(s, {})
	}
	return testing.expect(t, sim.player_at(s, player).state == .Playing, "the ship must be in play")
}

// A unit of `unit` there at once (no appear delay), and at `loc` exactly:
// some units spawn at a random offset from where they are asked for.
unit_spawn :: proc(t: ^testing.T, s: ^sim.State, unit: sim.Res_ID, loc: sim.Vec, owner := sim.NO_REF, stationary := false) -> (sim.Entity, bool) {
	req := sim.spawn_request(unit)
	req.loc = loc
	req.owner = owner
	req.stationary = stationary
	r := lifecycle.eg_request_spawn(s, req)
	if name := unit; !testing.expectf(t, sim.ref_valid(s, r), "%s must spawn", string(name[:])) {
		return {}, false
	}
	e := sim.entity_at(s, r.index)
	e.loc = loc
	e.appear_delay = 0
	return e, true
}

// A stationary mine at `loc` with `shields`: a target that stays put.
mine_spawn :: proc(t: ^testing.T, s: ^sim.State, loc: sim.Vec, shields: f32) -> sim.Entity {
	e, ok := unit_spawn(t, s, sim.res_id("mine"), loc, stationary = true)
	if ok {
		e.shields = shields
	}
	return e
}
