package data_plugins_tests

// Data plugins (D52), against the synthetic folders in
// tests/fixtures/plugins. A package of its own, because the fixtures have
// to be declared before sim.register_all, and the main suite must see the
// ids a game sees.

import "base:runtime"
import "core:os"
import "core:strings"
import "core:testing"
import vmem "core:mem/virtual"

import "dr:data"
import "dr:plugins/accent"
import "dr:sim"
import _ "dr:sim/core"
import "dr:sim/systems/level_system"

FIXTURES :: "tests/fixtures/plugins"

@(private = "file")
problems: []data.Plugin_Problem

@(init)
setup :: proc "contextless" () {
	context = runtime.default_context()
	declared: []sim.Plugin
	declared, problems = data.plugins_discover({FIXTURES})
	sim.plugins_declare(declared)
	sim.register_all()
}

@(private = "file")
find :: proc(t: ^testing.T, name: string) -> (sim.Plugin_ID, bool) {
	id, ok := sim.plugin_find(name)
	testing.expectf(t, ok, "%s not registered", name)
	return id, ok
}

// A folder with a plugin.json registers after every compiled plugin, from
// its manifest; one named like a compiled plugin only relabels it.
@(test)
data_plugins_register_after_the_compiled :: proc(t: ^testing.T) {
	units, ok := find(t, "fixture_units")
	if !ok {
		return
	}
	p := sim.registered_plugins()[units]
	testing.expect(t, p.data_only && p.content && p.session)
	testing.expect_value(t, p.label, "Fixture Units")
	testing.expect_value(t, p.version, "1")
	needs, _ := find(t, "fixture_needs")
	missing, _ := find(t, "fixture_missing")
	testing.expect(t, missing > accent.ID)
	testing.expect(t, missing < needs && needs < units, "not in name order")

	a := sim.registered_plugins()[accent.ID]
	testing.expect(t, !a.data_only)
	testing.expect_value(t, a.label, "Fixture Accent Label")
	testing.expect_value(t, a.version, "2")
	_, has := sim.plugin_find("Bad-Name")
	testing.expect(t, !has)
	testing.expect_value(t, len(problems), 1)
	if len(problems) == 1 {
		testing.expect(t, strings.has_suffix(problems[0].dir, "Bad-Name"), problems[0].dir)
	}
}

// Its units load after the game's, as a compiled plugin's do.
@(test)
data_plugin_content_loads :: proc(t: ^testing.T) {
	units, ok := find(t, "fixture_units")
	if !ok {
		return
	}
	dir, found := data.plugin_content_dir(units)
	testing.expect(t, found)
	testing.expect_value(t, dir, FIXTURES + "/fixture_units")
	_, found = data.plugin_content_dir(accent.ID)
	testing.expect(t, !found, "a plugin.json alone is content")

	defs: sim.Defs
	_, loaded := data.extra_defs_load(&defs, context.temp_allocator)
	testing.expect(t, loaded)
	testing.expect(t, int(units) in defs.content)
	seen := false
	for u in defs.units {
		seen ||= u.id == sim.res_id("fxun")
	}
	testing.expect(t, seen, "no fxun")
}

// One that needs a plugin nobody installed never runs, and says which;
// one that needs another data plugin runs with it.
@(test)
data_plugin_with_a_missing_dependency_stays_off :: proc(t: ^testing.T) {
	missing, ok := find(t, "fixture_missing")
	if !ok {
		return
	}
	dep, is_missing := sim.plugin_missing_dep(missing)
	testing.expect(t, is_missing)
	testing.expect_value(t, dep, "not_installed")
	testing.expect(t, int(missing) not_in sim.mods_resolve(sim.mods_with_deps({int(missing)})))

	needs, _ := find(t, "fixture_needs")
	units, _ := find(t, "fixture_units")
	_, needs_missing := sim.plugin_missing_dep(needs)
	testing.expect(t, !needs_missing)
	on := sim.mods_resolve(sim.mods_with_deps({int(needs)}))
	testing.expect(t, int(needs) in on && int(units) in on)
}

// One byte of content changes the digest, and so the registration hash:
// peers with different level packs refuse each other.
@(test)
content_digest_follows_every_byte :: proc(t: ^testing.T) {
	src :: FIXTURES + "/fixture_units"
	dst :: "build/data_plugins_test/fixture_units"
	os.make_directory_all(dst + "/data/unde")
	for rel in ([]string{"plugin.json", "data/unde/fxun.json"}) {
		blob, err := os.read_entire_file(strings.concatenate({src, "/", rel}, context.temp_allocator), context.temp_allocator)
		testing.expect(t, err == nil)
		_ = os.write_entire_file(strings.concatenate({dst, "/", rel}, context.temp_allocator), blob)
	}
	same := data.content_digest(src)
	testing.expect_value(t, data.content_digest(dst), same)

	path :: dst + "/data/unde/fxun.json"
	blob, _ := os.read_entire_file(path, context.temp_allocator)
	blob[len(blob) - 2] ~= 1
	_ = os.write_entire_file(path, blob)
	changed := data.content_digest(dst)
	testing.expect(t, changed != same)

	units, ok := find(t, "fixture_units")
	if !ok {
		return
	}
	sim.plugin_digest_set(units, same)
	before := sim.registration_hash()
	sim.plugin_digest_set(units, changed)
	testing.expect(t, sim.registration_hash() != before)
	sim.plugin_digest_set(units, 0)
}

// A campaign plugin's levels play in its manifest's order, each after the
// last, and are found only in it: its le01 is not the original's (D53).
@(test)
campaign_plays_its_levels_in_order :: proc(t: ^testing.T) {
	if !os.exists("assets/data/idli/gaob.json") {
		return
	}
	campaign, ok := find(t, "fixture_campaign")
	if !ok {
		return
	}
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	alloc := vmem.arena_allocator(&arena)
	defs, _ := data.assets_defs_load("assets", alloc)
	data.extra_defs_load(&defs, alloc)

	levels := sim.campaign_levels(&defs, campaign)
	if !testing.expect_value(t, len(levels), 2) {
		return
	}
	testing.expect_value(t, levels[0].identifier, "Omega")
	testing.expect_value(t, levels[1].identifier, "Alpha")
	testing.expect_value(t, levels[1].number, i32(2))
	testing.expect_value(t, sim.level_by_id(&defs, campaign, sim.level_id("le01")).identifier, "Alpha")
	testing.expect_value(t, sim.level_by_id(&defs, sim.CORE, sim.level_id("le01")).identifier, "Leonidas")
	testing.expect_value(t, len(sim.campaign_levels(&defs, sim.CORE)), 12)

	s := new(sim.State, alloc)
	sim.init(s, sim.Session{seed = 7, level_id = levels[0].id, game_type = .Single, campaign = campaign}, &defs)
	defer sim.destroy(s)
	seen := make([dynamic]string, 0, 2, alloc)
	append(&seen, sim.level_def(s).identifier)
	outcome := sim.Level_Transition.None
	for _ in 0 ..< 20_000 {
		for p in sim.players_of(s) {
			p.invulnerable_always = true
			p.invulnerable = true
		}
		sim.step(s, {})
		outcome = level_system.level_transition(s)
		if outcome == .Advanced {
			append(&seen, sim.level_def(s).identifier)
		} else if outcome != .None {
			break
		}
	}
	testing.expect_value(t, outcome, sim.Level_Transition.All_Complete)
	testing.expect_value(t, len(seen), 2)
	if len(seen) == 2 {
		testing.expect_value(t, seen[0], "Omega")
		testing.expect_value(t, seen[1], "Alpha")
	}
}
