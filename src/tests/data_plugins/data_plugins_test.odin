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
import "dr:game"
import "dr:plugins/accent"
import "dr:prefs"
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

// A level's look is read as it is written, and light it leaves out is
// the originals' (D54).
@(test)
campaign_level_look_loads :: proc(t: ^testing.T) {
	if !os.exists("assets/data/idli/gaob.json") {
		return
	}
	campaign, ok := find(t, "fixture_campaign")
	if !ok {
		return
	}
	a := data.assets_open("assets", context.temp_allocator)
	omega := data.assets_level_media(&a, campaign, sim.level_id("le02"))
	if !testing.expect(t, omega != nil) {
		return
	}
	testing.expect_value(t, omega.wind, data.Level_Wind{direction_degrees = 90, strength = 0.5})
	testing.expect_value(t, omega.lighting.sun_elevation_degrees, f32(55))
	testing.expect_value(t, omega.lighting.sun_azimuth_degrees, data.LIGHTING_MEASURED.sun_azimuth_degrees)
	testing.expect_value(t, omega.lighting.ambient, data.LIGHTING_MEASURED.ambient)
	alpha := data.assets_level_media(&a, campaign, sim.level_id("le01"))
	testing.expect(t, alpha != nil && alpha.lighting == data.LIGHTING_MEASURED)
	lucena := data.assets_level_media(&a, sim.CORE, sim.level_id("le07"))
	testing.expect(t, lucena != nil && lucena.lighting == data.LIGHTING_MEASURED && lucena.wind == {})
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
// last, and are found only in it: its le01 is not the original's (D53). Its
// first starts players with the weapons it names (D54).
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
	p := sim.player_at(s, 0)
	testing.expect_value(t, defs.weapons[p.weapons.air.weapon].id, sim.res_id("aipb"))
	testing.expect_value(t, defs.weapons[p.weapons.ground.weapon].id, sim.res_id("plbo"))
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

// Level Select and the lobby step through the campaigns on offer, round
// either end, and fall back to the first when the one shown is no longer
// offered; classic mode offers only the originals (D53). Classic Levels is
// not among the fixtures, so the fixture campaign is the only one on.
@(test)
campaigns_step_round_those_offered :: proc(t: ^testing.T) {
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

	ps := game.Prefs_State{saved = prefs.defaults()}
	ps.saved.classic = false
	ps.saved.mods = {int(campaign)}
	fl := game.Flow{defs = &defs, prefs = &ps}
	offered := game.flow_campaigns(&fl)
	testing.expect_value(t, len(offered), 1)
	testing.expect_value(t, game.flow_campaign_step(&fl, campaign, 1), campaign)
	testing.expect_value(t, game.flow_campaign_step(&fl, campaign, -1), campaign)
	testing.expect_value(t, game.flow_campaign_step(&fl, sim.CORE, 0), campaign)
	testing.expect_value(t, game.flow_campaign_label(campaign), "FIXTURE CAMPAIGN")
	testing.expect_value(t, game.flow_campaign_label(sim.CORE), "CLASSIC LEVELS")

	ps.saved.classic = true
	testing.expect_value(t, len(game.flow_campaigns(&fl)), 1)
	testing.expect_value(t, game.flow_campaign_step(&fl, campaign, 0), sim.CORE)
}
