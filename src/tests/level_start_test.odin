package tests

// Where and how a level starts (D54): a level's own start weapons, and
// starting further up its map for -row.

import "core:os"
import "core:slice"
import "core:testing"
import vmem "core:mem/virtual"

import "dr:data"
import "dr:plugins/loadout"
import "dr:sim"
import "dr:sim/systems/level_system"

// A level that names start weapons starts players with them, in place of
// the ones its number brings, unless a weapon chooser chooses; one that
// names none starts as the original's do.
@(test)
level_start_weapons_replace_the_level_rule :: proc(t: ^testing.T) {
	defs := synthetic_defs()
	weapons := make([]sim.Weapon, 4, context.temp_allocator)
	copy(weapons, defs.weapons)
	weapons[2] = defs.weapons[0]
	weapons[2].id = sim.res_id("wai5")
	weapons[2].minimum_level_available = 5
	weapons[3] = defs.weapons[1]
	weapons[3].id = sim.res_id("wgn2")
	defs.weapons = weapons

	start :: proc(defs: ^sim.Defs, mods: sim.Mods = {}) -> (air, ground: sim.Res_ID) {
		s := new(sim.State)
		defer free(s)
		sim.init(s, sim.Session{seed = 3, level_id = defs.levels[0].id, game_type = .Single, mods = mods}, defs)
		defer sim.destroy(s)
		p := sim.player_at(s, 0)
		return defs.weapons[p.weapons.air.weapon].id, defs.weapons[p.weapons.ground.weapon].id
	}
	air, ground := start(defs)
	testing.expect_value(t, air, sim.res_id("wair"))
	testing.expect_value(t, ground, sim.res_id("wgnd"))

	defs.levels[0].start_air = sim.res_id("wai5")
	defs.levels[0].start_ground = sim.res_id("wgn2")
	air, ground = start(defs)
	testing.expect_value(t, air, sim.res_id("wai5"))
	testing.expect_value(t, ground, sim.res_id("wgn2"))

	air, _ = start(defs, {int(loadout.ID)})
	testing.expect_value(t, air, sim.res_id("wair"))
}

// Begun at map row 1500, le07 has spawned exactly its placements from 64
// rows above the view (1436) to the view's bottom (1980), as at a level's
// start, and has every other still to meet.
@(test)
level_starts_at_a_row :: proc(t: ^testing.T) {
	if !os.exists("assets/data/idli/gaob.json") {
		return
	}
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	alloc := vmem.arena_allocator(&arena)
	defs, _ := data.assets_defs_load("assets", alloc)
	level := sim.level_by_id(&defs, sim.CORE, sim.level_id("le07"))
	if !testing.expect(t, level != nil) {
		return
	}
	s := new(sim.State, alloc)
	sim.init(s, sim.Session{seed = 7, level_id = level.id, game_type = .Single}, &defs)
	defer sim.destroy(s)
	level_system.level_start_at_row(s, 1500)

	b := sim.single(s, sim.Bgnd)
	testing.expect_value(t, b.view_top, i32(1500))
	testing.expect_value(t, b.view_bottom, i32(1980))
	pool := sim.single(s, sim.Pool)
	left := make([dynamic]i32, 0, len(level.placements), alloc)
	c := sim.Cursor{sim.NO_LINK}
	for _ in 0 ..< pool.required.count {
		append(&left, sim.trunc_i32(sim.group_at(s, sim.list_next(&pool.required, sim.group_links(s), &c)).loc.y))
	}
	want := make([dynamic]i32, 0, len(level.placements), alloc)
	met := 0
	for p in level.placements {
		if p.y < 1436 || p.y > 1980 {
			append(&want, p.y)
		} else {
			met += 1
		}
	}
	testing.expect(t, met > 0, "no placements in the view")
	slice.sort(left[:])
	slice.sort(want[:])
	testing.expect(t, slice.equal(left[:], want[:]), "not exactly the rows 1436-1980 spawned")
}
