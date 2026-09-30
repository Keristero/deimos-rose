package tests

import "core:log"
import "core:os"
import "core:testing"
import vmem "core:mem/virtual"

import "dr:data"
import "dr:sim"

// The game ships `assets/`, not the original install. Everything it reads from
// there must come out identical to what the original's own files produce,
// because Phase 4 verified the simulation against the original *through*
// `defs_load`. This test is what lets the two paths be trusted equally.
@(test)
assets_defs_match_the_original :: proc(t: ^testing.T) {
	if !os.exists("../game/ Data/Paks/Game.pak") || !os.exists("assets/sprites/index.json") {
		log.info("skipped: needs both the original install and an extracted assets tree")
		return
	}
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	alloc := vmem.arena_allocator(&arena)

	p := data.provider_open("../game", alloc)
	want, wr := data.defs_load(&p, alloc)
	got, gr := data.assets_defs_load("assets", alloc)

	testing.expect_value(t, gr.units, wr.units)
	testing.expect_value(t, gr.sprites, wr.sprites)
	testing.expect_value(t, gr.levels, wr.levels)
	testing.expect_value(t, gr.missing, wr.missing)
	testing.expect_value(t, gr.malformed, 0)

	testing.expect_value(t, got.perm_floats, want.perm_floats)
	testing.expect_value(t, got.perm_objects, want.perm_objects)
	testing.expect_value(t, got.perm_sounds, want.perm_sounds)

	// Units: same set, same states, same rules, same numbers. Comparing the
	// whole definition struct catches a field the JSON round-trip dropped.
	testing.expect_value(t, len(got.units), len(want.units))
	mismatched := 0
	for &w in want.units {
		g := sim.unit_find(&got, w.id)
		if g == nil {
			mismatched += 1
			log.errorf("unit %v missing from the assets tree", w.id)
			continue
		}
		if g.def != w.def {
			mismatched += 1
			log.errorf("unit %v: definition differs", w.id)
			continue
		}
		if len(g.states) != len(w.states) {
			mismatched += 1
			log.errorf("unit %v: %d states, expected %d", w.id, len(g.states), len(w.states))
			continue
		}
		for &ws, i in w.states {
			gs := &g.states[i]
			if gs.name != ws.name || gs.def != ws.def {
				mismatched += 1
				log.errorf("unit %v state %d (%v): differs", w.id, i, ws.name)
				break
			}
			if len(gs.rules) != len(ws.rules) || len(gs.spawn_sets) != len(ws.spawn_sets) {
				mismatched += 1
				log.errorf("unit %v state %d: %d rules/%d spawn sets, expected %d/%d",
					w.id, i, len(gs.rules), len(gs.spawn_sets), len(ws.rules), len(ws.spawn_sets))
				break
			}
			for wr2, j in ws.rules {
				if gs.rules[j] != wr2 {
					mismatched += 1
					log.errorf("unit %v state %d rule %d: differs", w.id, i, j)
					break
				}
			}
			for ss, j in ws.spawn_sets {
				if gs.spawn_sets[j] != ss {
					mismatched += 1
					log.errorf("unit %v state %d spawn set %d: differs", w.id, i, j)
					break
				}
			}
		}
	}
	testing.expect_value(t, mismatched, 0)

	// Players and weapons, including each weapon's split spawn records.
	testing.expect_value(t, len(got.players), len(want.players))
	for &w, i in want.players {
		testing.expect_value(t, got.players[i].id, w.id)
		testing.expect_value(t, got.players[i].def, w.def)
	}
	testing.expect_value(t, len(got.weapons), len(want.weapons))
	for &w, i in want.weapons {
		testing.expect_value(t, got.weapons[i].id, w.id)
		testing.expect_value(t, got.weapons[i].def, w.def)
		testing.expect_value(t, len(got.weapons[i].spawns), len(w.spawns))
		for s, j in w.spawns {
			testing.expect_value(t, got.weapons[i].spawns[j], s)
		}
	}

	// Sprite frame sizes: the baked index against the live plate cut.
	testing.expect_value(t, len(got.sprites), len(want.sprites))
	for &w in want.sprites {
		g := sim.sprite_find(&got, w.id)
		if !testing.expectf(t, g != nil, "sprite %v missing", w.id) {
			continue
		}
		if !testing.expectf(t, len(g.frames) == len(w.frames),
			"sprite %v: %d frames, expected %d", w.id, len(g.frames), len(w.frames)) {
			continue
		}
		for f, i in w.frames {
			testing.expectf(t, g.frames[i] == f, "sprite %v frame %d: %v, expected %v",
				w.id, i, g.frames[i], f)
		}
	}

	// Levels: order, geometry, placements, and the media mask pixel for pixel
	// -- the PNG has to reproduce the 16-bit TGA the original compares.
	testing.expect_value(t, len(got.levels), len(want.levels))
	for &w, i in want.levels {
		g := &got.levels[i]
		testing.expect_value(t, g.id, w.id)
		testing.expect_value(t, g.number, w.number)
		testing.expect_value(t, g.name, w.name)
		testing.expect_value(t, g.identifier, w.identifier)
		testing.expect_value(t, g.background, w.background)
		testing.expect_value(t, len(g.placements), len(w.placements))
		for pl, j in w.placements {
			testing.expect_value(t, g.placements[j], pl)
		}
		testing.expect_value(t, g.media_w, w.media_w)
		testing.expect_value(t, g.media_h, w.media_h)
		testing.expect_value(t, g.media_scale, w.media_scale)
		if len(g.media) == len(w.media) {
			diff := 0
			for v, j in w.media {
				if g.media[j] != v {
					diff += 1
				}
			}
			testing.expectf(t, diff == 0, "level %v: %d of %d mask pixels differ",
				w.id, diff, len(w.media))
		} else {
			testing.expectf(t, false, "level %v: mask %d pixels, expected %d",
				w.id, len(g.media), len(w.media))
		}
	}
	log.infof("assets: %d units, %d sprites, %d levels match the original",
		len(got.units), len(got.sprites), len(got.levels))
}

// The Classic Levels plugin lists the original's play order (D53): the
// twelve names built into the executable, which defs_load numbers by. And
// every level it lists is there, numbered by that list, as campaign CORE.
@(test)
classic_levels_play_in_the_original_order :: proc(t: ^testing.T) {
	dir, found := data.classic_levels_dir()
	if !testing.expect(t, found, "no plugins/classic_levels") {
		return
	}
	order := data.manifest_levels(dir)
	testing.expect_value(t, len(order), len(data.LEVEL_ORDER))
	for name, i in data.LEVEL_ORDER {
		if i < len(order) {
			testing.expect_value(t, order[i], name)
		}
	}
	if !os.exists("assets/data/idli/gaob.json") {
		return
	}
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	defs, _ := data.assets_defs_load("assets", vmem.arena_allocator(&arena))
	levels := sim.campaign_levels(&defs, sim.CORE)
	testing.expect_value(t, len(levels), 12)
	for &l, i in levels {
		testing.expect_value(t, l.identifier, data.LEVEL_ORDER[i])
		testing.expect_value(t, l.number, i32(i + 1))
	}
	testing.expect(t, sim.level_by_id(&defs, sim.CORE, sim.level_id("le07")).number == 1, "Lucena is not level 1")
}
