package passives_tests

// Passive Upgrades (plugins/passives): how a passive's levels add up, and
// what the passives do to the shipped weapons. A package of the plugin's
// own, as each plugin owns the tests of what it adds; the helpers are
// tests/support's. The rules are the design's (notes/passive-upgrades-and-
// easy-mode.md); these pin how they were read, see docs/passive-upgrades.md.
// The reward screen that hands them out is easy mode's (tests/).

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:testing"
import vmem "core:mem/virtual"

// Every plugin in the build, registered as the game registers them.
import _ "dr:game"
import "dr:plugins/easy_mode"
import "dr:plugins/passives"
import "dr:sim"
import "dr:sim/stats"
import support "dr:tests/support"

@(init)
setup :: proc "contextless" () {
	context = runtime.default_context()
	sim.register_all()
}

assets_defs :: support.assets_defs
content_defs :: support.content_defs
weapon_index :: support.weapon_index
play_start :: support.play_start

// Easy Mode, which brings Passive Upgrades, as a player who turned it on
// has it.
@(private = "file")
session_mods :: proc() -> sim.Mods {
	return sim.mods_session(sim.mods_switch_on({}, {int(easy_mode.ID)}))
}

@(test)
mod_value_takes_the_level_held_and_x_inherits :: proc(t: ^testing.T) {
	m := passives.Mod{.Charge_Rate, .Increase, {10, passives.X, 30}}
	cases := [4]struct{ level: u8, v: i16, ok: bool }{{0, 0, false}, {1, 10, true}, {2, 10, true}, {3, 30, true}}
	for c in cases {
		v, ok := passives.mod_value(m, c.level)
		testing.expectf(t, v == c.v && ok == c.ok, "level %d: got (%d, %v), want (%d, %v)", c.level, v, ok, c.v, c.ok)
	}
	// A stat that is x up to the level held is not touched at all.
	late := passives.Mod{.Risky_Reward, .Enables, {passives.X, 1, passives.X}}
	_, ok := passives.mod_value(late, 1)
	testing.expect(t, !ok, "an x first level must leave the stat alone")
}

@(test)
stat_totals_sum_across_passives :: proc(t: ^testing.T) {
	lv: passives.Passive_Levels
	lv[passives.IMPROVED_CHARGE] = 2 // Charge_Rate +20, Maximum_Charge +20
	lv[passives.AUTO_CHARGE] = 1     // Charge_Rate -50
	testing.expect_value(t, passives.stat_total(&lv, .Charge_Rate, sim.NONE).percent, -30)
	testing.expect_value(t, passives.stat_total(&lv, .Maximum_Charge, sim.NONE).percent, 20)
	testing.expect(t, passives.stat_total(&lv, .Auto_Charge_Air_To_Air, sim.NONE).enabled)
	testing.expect(t, !passives.stat_total(&lv, .Prevent_Overheat, sim.NONE).enabled, "level 2's switch is not on at level 1")
	lv[passives.AUTO_CHARGE] = 2
	testing.expect(t, passives.stat_total(&lv, .Prevent_Overheat, sim.NONE).enabled)
	testing.expect_value(t, passives.stat_total(&lv, .Charge_Rate, sim.NONE).percent, -30) // level 2 is x: still -50

	lv[passives.SHIELD_REGEN] = 3
	testing.expect_value(t, passives.stat_total(&lv, .Recharge_Delay, sim.NONE).extra, 0)
	testing.expect_value(t, passives.stat_total(&lv, .Shield_Regen_Rate, sim.NONE).extra, 2)
}

@(test)
weapon_passives_count_only_for_their_weapon :: proc(t: ^testing.T) {
	lv: passives.Passive_Levels
	lv[passives.WEAPON_1] = 1 // Ion Cannon: +1 projectile
	lv[passives.WEAPON_2] = 2 // Bacta Gun: +2 projectiles
	testing.expect_value(t, passives.stat_total(&lv, .Extra_Projectiles, passives.WEAPON_ION_CANNON).extra, 1)
	testing.expect_value(t, passives.stat_total(&lv, .Extra_Projectiles, passives.WEAPON_BACTA_GUN).extra, 2)
	testing.expect_value(t, passives.stat_total(&lv, .Extra_Projectiles, passives.WEAPON_PHOTON_BEAM).extra, 0)
	testing.expect_value(t, passives.stat_total(&lv, .Extra_Projectiles, sim.NONE).extra, 0)
	// Weapon 3's level 3 adds a volley and side fire to levels 1-2's delay.
	lv[passives.WEAPON_3] = 3
	testing.expect_value(t, passives.stat_total(&lv, .Extra_Volley, passives.WEAPON_REAR_GUN).extra, 1)
	testing.expect_value(t, passives.stat_total(&lv, .Firing_Delay, passives.WEAPON_REAR_GUN).percent, -20)
	testing.expect(t, passives.stat_total(&lv, .Side_Firing_Volley, passives.WEAPON_REAR_GUN).enabled)
}

// A weapon passive counts for its weapon in its own scope: a charge
// passive for the charge alone, any other for the shots alone. A ship
// passive counts in both.
@(test)
passives_count_in_their_own_scope :: proc(t: ^testing.T) {
	shots := passives.Passive_Def{weapon = passives.WEAPON_ION_CANNON}
	charge := passives.Passive_Def{weapon = passives.WEAPON_ION_CANNON, charge = true}
	ship := passives.Passive_Def{weapon = sim.NONE}
	testing.expect(t, passives.passive_applies(&shots, passives.WEAPON_ION_CANNON, false))
	testing.expect(t, !passives.passive_applies(&shots, passives.WEAPON_ION_CANNON, true))
	testing.expect(t, passives.passive_applies(&charge, passives.WEAPON_ION_CANNON, true))
	testing.expect(t, !passives.passive_applies(&charge, passives.WEAPON_ION_CANNON, false))
	testing.expect(t, !passives.passive_applies(&charge, passives.WEAPON_BACTA_GUN, true))
	testing.expect(t, passives.passive_applies(&ship, passives.WEAPON_ION_CANNON, true))
	testing.expect(t, passives.passive_applies(&ship, sim.NONE, false))
	// The shipped passives: Improved Charge, a ship passive, raises every
	// weapon's charge.
	lv: passives.Passive_Levels
	lv[passives.IMPROVED_CHARGE] = 1
	testing.expect_value(t, passives.stat_total(&lv, .Maximum_Charge, passives.WEAPON_PHOTON_BEAM, true).percent, 10)
	testing.expect_value(t, passives.stat_total(&lv, .Maximum_Charge, passives.WEAPON_PHOTON_BEAM).percent, 10)
	// The Ion Cannon's passive shapes its shots, not its charge.
	lv = {}
	lv[passives.WEAPON_1] = 1
	testing.expect_value(t, passives.stat_total(&lv, .Extra_Projectiles, passives.WEAPON_ION_CANNON).extra, 1)
	testing.expect_value(t, passives.stat_total(&lv, .Extra_Projectiles, passives.WEAPON_ION_CANNON, true).extra, 0)
}

// Against the shipped weapons (src/assets): the lanes the weapon passives
// add, and the backwards plasma bomb. Skipped without the assets tree.
@(test)
weapon_passives_shape_the_real_weapons :: proc(t: ^testing.T) {
	arena: vmem.Arena
	// The plugins' weapons too, for the passives other plugins register.
	defs, loaded := content_defs(t, &arena)
	if !loaded {
		return
	}
	defer vmem.arena_destroy(&arena)
	if !testing.expect(t, len(defs.levels) > 0, "the level list must load") {
		return
	}
	s := new(sim.State, context.temp_allocator)
	defer sim.destroy(s)
	sim.init(s, sim.Session{seed = 1, level_id = defs.levels[0].id, game_type = .Single, mods = session_mods()}, &defs)

	projectiles :: proc(s: ^sim.State, spawns: []stats.Weapon_Spawn) -> (n: int) {
		for sp in spawns {
			ui := sim.unit_index(s.defs, sp.unit)
			if ui >= 0 && s.defs.units[ui].player_projectile {
				n += 1
			}
		}
		return
	}
	out, before: [64]stats.Weapon_Spawn
	p := sim.player_at(s, 0)

	ion := weapon_index(t, &defs, passives.WEAPON_ION_CANNON)
	if ion < 0 {
		return
	}
	nb := stats.weapon_spawns(s, ion, 0, false, before[:])
	// With no passive held, the spawn list is the weapon's own, as it was.
	wd := &defs.weapons[ion]
	k := 0
	for &sp in wd.spawns {
		if sp.unit == sim.NONE {
			continue
		}
		testing.expectf(t, before[k].unit == sp.unit && before[k].x == sp.x_loc && before[k].y == sp.y_loc && before[k].angle == sp.angle,
			"ion spawn %d changed with no passive held", k)
		k += 1
	}
	testing.expect_value(t, nb, k)
	passives.levels_of(s, p.number)^[passives.WEAPON_1] = 1
	n := stats.weapon_spawns(s, ion, 0, false, out[:])
	testing.expect_value(t, projectiles(s, out[:n]), projectiles(s, before[:nb]) + 1)
	passives.levels_of(s, p.number)^[passives.WEAPON_1] = 2 // x at level 2: still the one extra
	n = stats.weapon_spawns(s, ion, 0, false, out[:])
	testing.expect_value(t, projectiles(s, out[:n]), projectiles(s, before[:nb]) + 1)
	passives.levels_of(s, p.number)^[passives.WEAPON_1] = 3 // two, not three: only the level held counts
	n = stats.weapon_spawns(s, ion, 0, false, out[:])
	testing.expect_value(t, projectiles(s, out[:n]), projectiles(s, before[:nb]) + 2)

	// The Bacta Gun's passive leaves the Ion Cannon alone.
	passives.levels_of(s, p.number)^ = {passives.WEAPON_2 = 3}
	n = stats.weapon_spawns(s, ion, 0, false, out[:])
	testing.expect_value(t, n, nb)

	// The plasma bomb, backwards: every spawn mirrored behind the ship.
	bomb := weapon_index(t, &defs, passives.WEAPON_PLASMA_BOMB)
	if bomb < 0 {
		return
	}
	passives.levels_of(s, p.number)^ = {passives.GROUND_VARIANT_1 = 1}
	fwd := stats.weapon_spawns(s, bomb, 0, false, before[:])
	back := stats.weapon_spawns(s, bomb, 0, true, out[:])
	testing.expect_value(t, back, fwd)
	for i in 0 ..< back {
		testing.expect_value(t, out[i].y, -before[i].y)
		testing.expect(t, out[i].set_heading)
		testing.expect_value(t, out[i].angle, (540 - before[i].angle) % 360)
	}
	// Level 3 drops one more bomb.
	passives.levels_of(s, p.number)^ = {passives.GROUND_VARIANT_1 = 3}
	n = stats.weapon_spawns(s, bomb, 0, true, out[:])
	testing.expect_value(t, projectiles(s, out[:n]), projectiles(s, before[:fwd]) + 1)

	// Every weapon passive is offered only where its weapon flies.
	testing.expect(t, passives.passive_available(s, passives.WEAPON_1, 1))
	testing.expect(t, passives.passive_available(s, passives.GROUND_VARIANT_1, i32(len(defs.levels))))
	for i in 0 ..< passives.passive_count() {
		def := passives.passive_def(passives.Passive(i))
		if def.weapon == sim.NONE {
			continue
		}
		testing.expectf(t, weapon_index(t, &defs, def.weapon) >= 0, "%s's weapon is not in the data", def.name)
		// A plugin's passive only while that plugin is on, as no other
		// plugin is in this session.
		if def.plugin != sim.CORE {
			testing.expectf(t, !passives.passive_available(s, passives.Passive(i), i32(len(defs.levels))), "%s offered without its plugin", def.name)
		}
	}
}

// Every passive has an icon recipe (tools/icons/passives.json), and the icon
// `mise run assets:icons` makes from it is in the assets tree, under the name
// the reward screen looks for, its Passive_Def.name. The recipe
// check needs nothing but the repository; the file check skips without the
// assets tree.
@(test)
every_passive_has_an_icon :: proc(t: ^testing.T) {
	text, err := os.read_entire_file("tools/icons/passives.json", context.temp_allocator)
	if !testing.expectf(t, err == nil, "cannot read the icon recipe: %v", err) {
		return
	}
	Recipe :: struct {
		size:  int,
		icons: []struct {
			name: string,
		},
	}
	recipe: Recipe
	if !testing.expect(t, json.unmarshal(text, &recipe, allocator = context.temp_allocator) == nil, "the icon recipe must parse") {
		return
	}
	testing.expect_value(t, recipe.size, 32)
	assets := os.exists("assets/data/index.json")
	if !assets {
		log.info("icon files not checked: needs the extracted assets tree")
	}
	for i in 0 ..< passives.passive_count() {
		name := passives.passive_def(passives.Passive(i)).name
		found := false
		for icon in recipe.icons {
			found ||= icon.name == name
		}
		testing.expectf(t, found, "no icon recipe named %q", name)
		if assets {
			path := fmt.tprintf("assets/icons/passives/%s.png", name)
			testing.expectf(t, os.exists(path), "%s is missing: run mise run assets:icons", path)
		}
	}
}

// Weapon 3's side fire goes out on one volley of each shot, not on the
// extra volley as well. One press of the Rear Gun at level 3: the bullets
// heading sideways number what one volley's forward-facing sets fire, and
// every one leaves on the same step. Skipped without the extracted data.
@(test)
rear_gun_fires_one_volley_to_the_sides :: proc(t: ^testing.T) {
	arena: vmem.Arena
	defs, loaded := assets_defs(t, &arena)
	if !loaded {
		return
	}
	defer vmem.arena_destroy(&arena)
	rear := -1
	for &w, i in defs.weapons {
		if w.id == passives.WEAPON_REAR_GUN {
			rear = i
		}
	}
	if !testing.expect(t, rear >= 0, "no Rear Gun in the data") {
		return
	}
	s := new(sim.State, context.temp_allocator)
	defer sim.destroy(s)
	if !play_start(t, s, sim.Session{seed = 1, level_id = defs.levels[0].id, game_type = .Single, mods = session_mods()}, &defs) {
		return
	}
	p := sim.player_at(s, 0)
	p.weapons.air.weapon = i32(rear)
	passives.levels_of(s, 0)[passives.WEAPON_3] = 3
	p.invulnerable_always, p.invulnerable = true, true

	seen: [dynamic]i32
	seen.allocator = context.temp_allocator
	sideways, forward: int
	steps: [dynamic]i32
	steps.allocator = context.temp_allocator
	for i in 0 ..< 60 {
		input: sim.Frame_Input
		if i == 0 {
			input[0] = {.Fire_Air}
		}
		sim.session_step(s, input)
		walk := sim.walk_entities(s)
		for e in sim.walk_next(&walk) {
			if e.deleted || !s.defs.units[e.unit].player_projectile || e.owner_player != 0 {
				continue
			}
			known := false
			for n in seen {
				known ||= n == e.number
			}
			if known {
				continue
			}
			append(&seen, e.number)
			time := sim.single(s, sim.Clock).time
			if abs(e.vel.x) > abs(e.vel.y) {
				sideways += 1
				if len(steps) == 0 || steps[len(steps) - 1] != time {
					append(&steps, time)
				}
			} else if e.vel.y < 0 {
				forward += 1
			}
		}
	}
	log.infof("forward %d, sideways %d, on steps %v", forward, sideways, steps[:])
	testing.expect(t, sideways > 0, "level 3 must fire to the sides")
	testing.expect(t, forward > sideways, "the extra volley must not fire to the sides as well")
	testing.expect_value(t, len(steps), 1)
}
