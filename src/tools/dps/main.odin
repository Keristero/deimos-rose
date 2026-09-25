// The DPS report (notes/dps-report.md; docs/dps-report.md records how it
// was read): how much damage each weapon deals, and how much each passive at
// each of its levels adds to it, measured in the simulation alone.
//
//   dps <assets root> <out dir> [-seconds:N] [-stage:N] [-threads:N] [-weapon:NAME]
//
// -weapon limits the runs to one weapon, named as the report names it
// ("Rear Gun"; case does not matter), and writes dps-YYYY-MM-DD-rear-gun.html
// so the full report is not overwritten.
//
// Every run is a fresh sim.State on a copy of the stage with nothing placed
// in it. Once the ship is in play the run gives it the weapon and the
// passive levels under test, lets the crosshair settle, and then spawns
// targets: a stand-in enemy that never moves, fires or dies. Its shields are
// topped back up after every step, and the damage is what was taken off
// them. Four scenarios: one target ahead, a cluster of five ahead, one
// target behind, and a wave of nine ahead. The wave is the one whose
// targets die: each has a real enemy's shields, is replaced a moment after
// it is shot down, and only the shields taken off count, so what a weapon
// wastes on overkill is seen, and what it carries through a kill (the
// Discharge Beam's leftover damage and shrapnel) is too.
//
// A weapon is fired under every input policy weapon_policies lists, and the
// report keeps two sets: primary fire (the best of the taps, and of holding
// where holding fires), and charge shots (charging to full and releasing).
// Either way the DPS is the damage over the whole measured time, so a charge
// shot's includes the time spent charging it. Every number is what a
// perfect player would get from that loadout.
// Every run uses the same seed, so a passive's gain is paired with the
// baseline it is measured against.
//
// It writes <out dir>/dps-YYYY-MM-DD.html and prints a summary. No window,
// no audio: only the sim runs.
package dps

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "dr:data"
import "dr:sim"

SEED :: 0x5eed_d95
STEP_HZ :: 30

// Where the targets stand. Air targets are this far straight ahead of (or
// behind) the ship. Ground targets are as far from it as the crosshair,
// where the bombs land: ahead, or behind -- where Ground Variant 1 turns the
// bombs to.
// Provisional: picked to be well inside every air weapon's reach (the Bacta
// Gun's is the shortest, 240 px).
AIR_RANGE :: 120

// The cluster: a loose V of five, open towards the ship, about as tight as
// the game's own formations fly. Provisional, by eye.
CLUSTER := [5]sim.Vec{{0, 0}, {-40, 0}, {40, 0}, {-20, -34}, {20, -34}}

// The wave: three rows of three, as far apart as the cluster's, from where
// the single target stands and away from the ship.
WAVE := [9]sim.Vec{{0, 0}, {-40, 0}, {40, 0}, {0, -34}, {-40, -34}, {40, -34}, {0, -68}, {-40, -68}, {40, -68}}

// A wave target's shields: about a stage 9-12 air enemy's. Provisional.
WAVE_SHIELDS :: 0.8

// Steps before a wave target shot down is replaced. Provisional: about the
// gap between the rows of a formation flying in.
WAVE_RESPAWN_STEPS :: 12

// A target's shields, put back after every step. Far above any one step's
// damage, so a target is never destroyed, and small enough that an f32 still
// holds a hundredth of a point.
TARGET_SHIELDS :: 10000

// The stand-in enemies are copies of these, so that they are the size of a
// real enemy and cost a shot what a real one does (a shot that hits takes
// the target's own damage).
AIR_TARGET_FROM :: "blha"    // BlackHawk
GROUND_TARGET_FROM :: "tala" // Tank - Laser
AIR_TARGET :: "dpsa"
GROUND_TARGET :: "dpsg"
AIR_WAVE_TARGET :: "dpwa"
GROUND_WAVE_TARGET :: "dpwg"

// Steps allowed for the ship to fly in, and for the crosshair to reach its
// full distance once the weapon is set.
ENTRY_STEPS :: 600
SETTLE_STEPS :: 90

// Tap cadences tried, in steps between presses.
TAP_MIN :: 2
TAP_MAX :: 40

Scenario :: enum u8 {
	Single,
	Cluster,
	Behind,
	Wave,
}

SCENARIO_NAMES := [Scenario]string {
	.Single  = "Single target",
	.Cluster = "Cluster of 5",
	.Behind  = "Target behind",
	.Wave    = "Wave of 9",
}

// The two sets the report keeps.
Mode :: enum u8 {
	Primary, // taps, and holding where it fires; never a charge
	Charge,  // charge to full, release, repeat
}

MODE_NAMES := [Mode]string {
	.Primary = "Primary fire",
	.Charge  = "Charge shots",
}

Policy_Kind :: enum u8 {
	Tap,    // press for one step every `period` steps
	Hold,   // hold fire throughout (under Auto Charge this autofires)
	Charge, // charge to the full power level, release, repeat
}

Policy :: struct {
	kind:   Policy_Kind,
	period: i32,
}

// A loadout under test: nothing, or one passive at one level.
Config :: struct {
	has:     bool,
	passive: sim.Passive,
	level:   u8,
}

Weapon_Case :: struct {
	index:  i32, // in Defs.weapons
	id:     sim.Res_ID,
	name:   string,
	unlock: i32, // minimum_level_available
	ground: bool,
	charge: bool, // has an air power-up to charge
}

Job :: struct {
	weapon:   int,
	scenario: Scenario,
	config:   int,
	policy:   Policy,
}

Outcome :: struct {
	ok:     bool,
	damage: f64, // over the measured steps, all targets together
	hits:   i32,
	// A charge began while measuring: under Auto Charge a slow enough tap
	// lets one build, and that run is not primary fire.
	charged: bool,
}

Best :: struct {
	tried:  bool,
	dps:    f64,
	hits:   f64, // hits a second, all targets together
	policy: Policy,
}

// Per weapon, mode, scenario and loadout.
Table :: [][Mode][Scenario][]Best

Shared :: struct {
	defs:     ^sim.Defs,
	weapons:  []Weapon_Case,
	configs:  []Config,
	jobs:     []Job,
	outcomes: []Outcome,
	steps:    int,
	next:     int, // the next job to take, atomically
}

main :: proc() {
	if len(os.args) < 3 {
		fmt.eprintln("usage: dps <assets root> <out dir> [-seconds:N] [-stage:N] [-threads:N] [-weapon:NAME]")
		os.exit(2)
	}
	root, out_dir := os.args[1], os.args[2]
	seconds, stage, threads := 60, 7, os.get_processor_core_count()
	only := ""
	for a in os.args[3:] {
		key, _, val := strings.partition(a, ":")
		if key == "-weapon" {
			only = strings.trim_space(val)
			continue
		}
		n, ok := strconv.parse_int(val)
		if !ok || n < 1 {
			fmt.eprintfln("dps: bad option %s", a)
			os.exit(2)
		}
		switch key {
		case "-seconds":
			seconds = n
		case "-stage":
			stage = n
		case "-threads":
			threads = n
		case:
			fmt.eprintfln("dps: unknown option %s", a)
			os.exit(2)
		}
	}

	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		fmt.eprintln("dps: out of memory")
		os.exit(1)
	}
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)
	defs, _ := data.assets_defs_load(root, alloc)
	if len(defs.levels) == 0 || len(defs.weapons) == 0 {
		fmt.eprintfln("dps: no game data under %s (run mise run assets:all)", root)
		os.exit(1)
	}
	if _, ok := data.extra_defs_load(root, &defs, alloc); !ok {
		fmt.eprintfln("dps: cannot load the new content under %s/extra", root)
		os.exit(1)
	}
	if !dps_prepare(&defs, i32(stage), alloc) {
		os.exit(1)
	}

	sh := Shared {
		defs  = &defs,
		steps = seconds * STEP_HZ,
	}
	sh.weapons = dps_weapons(&defs, alloc)
	if only != "" {
		ok: bool
		if sh.weapons, ok = dps_only(sh.weapons, only); !ok {
			os.exit(2)
		}
	}
	sh.configs = dps_configs(alloc)
	sh.jobs = dps_jobs(&sh, alloc)
	sh.outcomes = make([]Outcome, len(sh.jobs), alloc)
	fmt.eprintfln("dps: %d weapons, %d loadouts, %d runs of %d s on %d threads",
		len(sh.weapons), len(sh.configs), len(sh.jobs), seconds, threads)

	start := time.tick_now()
	workers := make([]^thread.Thread, max(threads, 1), alloc)
	for &w in workers {
		w = thread.create_and_start_with_data(&sh, dps_worker)
	}
	for w in workers {
		thread.join(w)
		thread.destroy(w)
	}
	fmt.eprintfln("dps: ran in %.1f s", time.duration_seconds(time.tick_since(start)))

	failed := 0
	for o in sh.outcomes {
		if !o.ok {
			failed += 1
		}
	}
	if failed > 0 {
		fmt.eprintfln("dps: %d runs could not be set up", failed)
		os.exit(1)
	}

	best := dps_best(&sh, alloc)
	date := dps_date()
	html := report_html(&sh, best, date, seconds, stage)
	if err := os.make_directory_all(out_dir); err != nil && err != .Exist {
		fmt.eprintfln("dps: cannot make %s: %v", out_dir, err)
		os.exit(1)
	}
	suffix := ""
	if only != "" {
		slug, _ := strings.replace_all(strings.to_lower(sh.weapons[0].name, context.temp_allocator), " ", "-", context.temp_allocator)
		suffix = fmt.tprintf("-%s", slug)
	}
	path := fmt.aprintf("%s/dps-%s%s.html", out_dir, date, suffix, allocator = alloc)
	if err := os.write_entire_file(path, transmute([]u8)html); err != nil {
		fmt.eprintfln("dps: cannot write %s: %v", path, err)
		os.exit(1)
	}
	report_text(&sh, best)
	fmt.printfln("wrote %s", path)
}

dps_date :: proc() -> string {
	y, m, d := time.date(time.now())
	return fmt.tprintf("%04d-%02d-%02d", y, int(m), d)
}

// The stage, emptied, as the only level; and the stand-in targets appended
// to the units.
dps_prepare :: proc(d: ^sim.Defs, stage: i32, alloc := context.allocator) -> bool {
	lv := -1
	for &l, i in d.levels {
		if l.number == stage {
			lv = i
		}
	}
	if lv < 0 {
		fmt.eprintfln("dps: no stage %d", stage)
		return false
	}
	levels := make([]sim.Level_Def, 1, alloc)
	levels[0] = d.levels[lv]
	levels[0].placements = nil
	d.levels = levels

	pairs := [4][2]string {
		{AIR_TARGET_FROM, AIR_TARGET},
		{GROUND_TARGET_FROM, GROUND_TARGET},
		{AIR_TARGET_FROM, AIR_WAVE_TARGET},
		{GROUND_TARGET_FROM, GROUND_WAVE_TARGET},
	}
	units := make([]sim.Unit, len(d.units) + len(pairs), alloc)
	copy(units, d.units)
	for pair, k in pairs {
		from := sim.unit_index(d, sim.res_id(pair[0]))
		if from < 0 {
			fmt.eprintfln("dps: no unit %s to copy a target from", pair[0])
			return false
		}
		units[len(d.units) + k] = target_unit(&d.units[from], sim.res_id(pair[1]), k >= 2 ? WAVE_SHIELDS : TARGET_SHIELDS, alloc)
	}
	d.units = units
	return true
}

// A copy of `u` that stands still, never fires and never changes state: one
// state, the unit's first, stripped of everything that moves or spawns.
// When it dies it leaves nothing behind: no debris, coins or bonus that
// could take or give a hit.
target_unit :: proc(u: ^sim.Unit, id: sim.Res_ID, shields: f32, alloc := context.allocator) -> sim.Unit {
	t := u^
	t.id = id
	t.shields_base_amount = shields
	t.shields_level_increment = 0
	t.shields_max_amount = shields
	t.destruct_spawn = sim.NONE
	t.destruct_num_coins_to_release = 0
	t.destruct_coin, t.destruct_coin_on_group_kill = sim.NONE, sim.NONE
	t.destruct_release_random_bonus = false
	t.destruct_destroy_children, t.destruct_delete_children = false, false
	t.destruct_draw_to_terrain, t.destruct_create_obstacle = false, false
	t.destruct_notice = ""
	t.initial_speed_min, t.initial_speed_max = 0, 0
	// One to a request, exactly where it is asked for.
	t.num_in_group_min, t.num_in_group_max = 1, 1
	t.appears_percent = 100
	t.x_offset_min, t.x_offset_max, t.y_offset_min, t.y_offset_max = 0, 0, 0, 0
	t.group_delay_min, t.group_delay_max = 0, 0
	t.can_be_spawned_only_when_players_active = false
	t.hittable_when_invisible = true
	t.can_be_hit_by_player_projectile = true
	t.harmless_to_players = false
	states := make([]sim.Unit_State, 1, alloc)
	st := &states[0]
	st^ = u.states[0]
	st.spawn_sets = nil
	st.rules = nil
	st.collides = true
	st.pause_vertical_scrolling = true
	st.on_timer_min, st.on_timer_max = 0, 0
	st.on_timer_change_to = ""
	st.on_counter = 0
	st.on_counter_change_to = ""
	st.on_range = 0
	st.on_range_change_to = ""
	st.on_hit_change_to = ""
	st.hunts, st.cyclic_motion, st.flee = false, false, sim.NONE
	st.hold_position_to_target, st.do_rotate_to_target = false, false
	st.max_speed, st.delta, st.hold_max_speed, st.hold_delta = 0, 0, 0, 0
	st.invulnerable_until_all_children_destroyed = false
	st.invulnerable_until_owner_destroyed = false
	st.invulnerable_shields_do_not_deplete_on_collision = false
	st.use_this_state_on_shield_depletion = false
	st.collides_with_players = false
	st.delete_on_no_active_players, st.destruct_on_no_active_players = false, false
	st.destruct_if_vertical_scrolling_not_paused = false
	st.lock_to_owner_loc, st.link_to_owner_loc, st.orbit_owner = false, false, false
	st.pass_hits_to_owner = false
	st.entry_sound = sim.NONE
	st.collision_spawn = sim.NONE
	st.particles = sim.NONE
	st.required_visibility_percent, st.visibility_delta_percent = 100, 0
	t.states = states
	return t
}

// Every air weapon, and the ground weapon, in the order they unlock.
dps_weapons :: proc(d: ^sim.Defs, alloc := context.allocator) -> []Weapon_Case {
	out := make([dynamic]Weapon_Case, alloc)
	for &w, i in d.weapons {
		if w.type != sim.WEP_AIR && w.type != sim.WEP_GROUND {
			continue
		}
		append(&out, Weapon_Case {
			index  = i32(i),
			id     = w.id,
			unlock = w.minimum_level_available,
			name   = strings.trim_prefix(strings.trim_prefix(w.name, "Air - "), "Ground - "),
			ground = w.type == sim.WEP_GROUND,
			charge = w.type == sim.WEP_AIR && !w.auto_repeat &&
				(w.powerup_air_activation_spawn != sim.NONE || w.powerup_air_release_spawn != sim.NONE),
		})
	}
	slice.sort_by(out[:], proc(a, b: Weapon_Case) -> bool {
		if a.ground != b.ground {
			return !a.ground
		}
		return a.unlock != b.unlock ? a.unlock < b.unlock : a.index < b.index
	})
	return out[:]
}

// The one weapon named, as a slice of `ws`; or, naming none of them, a
// message listing the names there are.
dps_only :: proc(ws: []Weapon_Case, name: string) -> ([]Weapon_Case, bool) {
	for &w, i in ws {
		if strings.equal_fold(w.name, name) {
			return ws[i:i + 1], true
		}
	}
	fmt.eprintfln("dps: no weapon %q; the weapons are:", name)
	for w in ws {
		fmt.eprintfln("    %s", w.name)
	}
	return nil, false
}

// The baseline, then every level of every passive.
dps_configs :: proc(alloc := context.allocator) -> []Config {
	out := make([dynamic]Config, alloc)
	append(&out, Config{})
	for &def, pa in sim.PASSIVES {
		for l in 1 ..= def.levels {
			append(&out, Config{true, pa, l})
		}
	}
	return out[:]
}

config_levels :: proc(c: Config) -> (lv: sim.Passive_Levels) {
	if c.has {
		lv[c.passive] = c.level
	}
	return
}

config_name :: proc(c: Config) -> string {
	if !c.has {
		return "none"
	}
	return fmt.tprintf("%s %d", passive_name(c.passive), c.level)
}

passive_name :: proc(p: sim.Passive) -> string {
	n, _ := fmt.enum_value_to_string(p)
	s, _ := strings.replace_all(n, "_", " ", context.temp_allocator)
	return s
}

// The policies worth trying for a weapon under a loadout: taps at every
// cadence; for a weapon with a power-up, charging; and, under Auto Charge
// (where holding autofires) or for an auto-repeat weapon, holding. Holding a
// charge weapon otherwise sits on a full charge until it overheats, which
// hurts the ship, so it is left out.
weapon_policies :: proc(w: Weapon_Case, c: Config, out: ^[dynamic]Policy) {
	for p in TAP_MIN ..= TAP_MAX {
		append(out, Policy{.Tap, i32(p)})
	}
	if w.ground {
		return
	}
	auto_charge := c.has && c.passive == .Auto_Charge
	if w.charge {
		append(out, Policy{.Charge, 0})
	}
	if auto_charge || !w.charge {
		append(out, Policy{.Hold, 0})
	}
}

dps_jobs :: proc(sh: ^Shared, alloc := context.allocator) -> []Job {
	out := make([dynamic]Job, alloc)
	pols := make([dynamic]Policy, context.temp_allocator)
	for w, wi in sh.weapons {
		for c, ci in sh.configs {
			clear(&pols)
			weapon_policies(w, c, &pols)
			for sc in Scenario {
				for p in pols {
					append(&out, Job{wi, sc, ci, p})
				}
			}
		}
	}
	return out[:]
}

dps_worker :: proc(data: rawptr) {
	sh := (^Shared)(data)
	for {
		i := sync.atomic_add(&sh.next, 1)
		if i >= len(sh.jobs) {
			return
		}
		j := sh.jobs[i]
		sh.outcomes[i] = dps_run(sh.defs, sh.weapons[j.weapon], j.scenario, config_levels(sh.configs[j.config]), j.policy, sh.steps)
		free_all(context.temp_allocator)
	}
}

// The fire button for this step under the policy, from the state before it.
policy_fire :: proc(s: ^sim.State, h: ^sim.Weapon_Handler, pol: Policy, k: int) -> bool {
	switch pol.kind {
	case .Tap:
		return k % int(pol.period) == 0
	case .Hold:
		return true
	case .Charge:
		pu := &h.air_powerup
		full := pu.state == 1 && pu.percent >= 100 || pu.state == 2
		if sim.air_auto_charge(s, h) {
			// It charges while fire is let go; a press releases it.
			return full
		}
		// Hold to charge, let go for a step to release it at full power, and
		// hold again straight away so the next charge starts as soon as the
		// release is spent.
		return !full
	}
	return false
}

dps_run :: proc(d: ^sim.Defs, w: Weapon_Case, sc: Scenario, levels: sim.Passive_Levels, pol: Policy, steps: int) -> (o: Outcome) {
	s := new(sim.State)
	defer free(s)
	sim.init(s, sim.Session{seed = SEED, level_id = d.levels[0].id, game_type = .Single}, d)
	p := &s.players[0]
	for i := 0; i < ENTRY_STEPS && p.state != .Playing; i += 1 {
		sim.session_step(s, {})
	}
	if p.state != .Playing {
		return
	}
	p.passives = levels
	h := &p.weapons
	sim.change_weapon(s, h, w.ground ? sim.WEP_GROUND : sim.WEP_AIR, w.index)
	sim.player_sprite_from_weapon(s, p)
	for _ in 0 ..< SETTLE_STEPS {
		sim.session_step(s, {})
		// Every run starts uncharged. Under Auto Charge a charge builds while
		// fire is let go, so the idle count is kept at 0 as if fire were held,
		// without the shots that holding would put in the air.
		h.air_idle = 0
	}
	if (w.ground ? h.ground.weapon : h.air.weapon) != w.index {
		return
	}

	centre := p.loc + (sc == .Behind ? sim.Vec{0, AIR_RANGE} : sim.Vec{0, -AIR_RANGE})
	if w.ground {
		// Under the crosshair, where the bombs land: ahead where it stands,
		// behind where it stands once a passive turns the bombs round. The
		// crosshair in use must be where ground_aim says, or the targets
		// would stand where nothing lands.
		fwd, back := ground_aim(s, p)
		centre = sc == .Behind ? back : fwd
		if at := sim.ground_fires_backwards(s, h) ? back : fwd; at != h.crosshair.loc {
			return
		}
	}
	offsets: []sim.Vec
	unit := w.ground ? GROUND_TARGET : AIR_TARGET
	switch sc {
	case .Single, .Behind:
		offsets = CLUSTER[:1]
	case .Cluster:
		offsets = CLUSTER[:]
	case .Wave:
		offsets = WAVE[:]
		unit = w.ground ? GROUND_WAVE_TARGET : AIR_WAVE_TARGET
	}
	targets: [len(WAVE)]sim.Entity_Ref
	anchors: [len(WAVE)]sim.Vec
	left: [len(WAVE)]f32 // a wave target's shields after the last step
	down: [len(WAVE)]int // the step a wave target was shot down
	for off, i in offsets {
		anchors[i] = centre + off
		targets[i] = target_spawn(s, unit, anchors[i])
		if !sim.ref_valid(s, targets[i]) {
			return
		}
		left[i] = sim.entity_at(s, targets[i].index).shields
	}

	button: sim.Button = w.ground ? .Fire_Ground : .Fire_Air
	for k in 0 ..< steps {
		b: sim.Buttons
		if policy_fire(s, h, pol, k) {
			b += {button}
		}
		sim.session_step(s, {b, {}})
		// The air weapon charges under Auto Charge while the Plasma Bomb is
		// fired, but its shots cannot reach a ground target.
		o.charged ||= !w.ground && h.air_powerup.state != 0
		for i in 0 ..< len(offsets) {
			if sc == .Wave {
				if left[i] <= 0 {
					if k - down[i] >= WAVE_RESPAWN_STEPS {
						targets[i] = target_spawn(s, unit, anchors[i])
						if !sim.ref_valid(s, targets[i]) {
							return
						}
						left[i] = sim.entity_at(s, targets[i].index).shields
					}
					continue
				}
				if !sim.ref_valid(s, targets[i]) {
					// Shot down: only the shields it had count.
					o.damage += f64(left[i])
					o.hits += 1
					left[i], down[i] = 0, k
					continue
				}
				e := sim.entity_at(s, targets[i].index)
				if drop := left[i] - e.shields; drop > 0 {
					o.damage += f64(drop)
					o.hits += 1
				}
				left[i] = e.shields
				e.loc, e.vel = anchors[i], {}
				continue
			}
			if !sim.ref_valid(s, targets[i]) {
				return
			}
			e := sim.entity_at(s, targets[i].index)
			if drop := TARGET_SHIELDS - e.shields; drop > 0 {
				o.damage += f64(drop)
				o.hits += 1
			}
			e.shields = TARGET_SHIELDS
			e.loc, e.vel = anchors[i], {}
		}
	}
	o.ok = true
	return
}

// Where the ground crosshair stands, ahead and turned round, at the ship's
// current reach: the sums in player.odin's crosshair update. Turned round
// it is half the reach behind the ship, kept on screen at the bottom.
ground_aim :: proc(s: ^sim.State, p: ^sim.Player) -> (fwd, back: sim.Vec) {
	gw := &s.defs.weapons[p.weapons.ground.weapon]
	half := f32(sim.halve(p.weapons.crosshair.dims.y))
	x := f32(gw.crosshair_x_offset) + p.loc.x
	fwd = {x, max(f32(p.crosshair_reach + gw.crosshair_y_offset) + p.loc.y, half)}
	back = {x, min(p.loc.y - f32(p.crosshair_reach + gw.crosshair_y_offset) / 2, f32(sim.view_height(s.defs)) - half)}
	return
}

// A target, exactly at `at` and ready to be hit.
target_spawn :: proc(s: ^sim.State, unit: string, at: sim.Vec) -> sim.Entity_Ref {
	req := sim.spawn_request(sim.res_id(unit))
	req.loc = at
	req.stationary = true
	r := sim.eg_request_spawn(s, req)
	if sim.ref_valid(s, r) {
		e := sim.entity_at(s, r.index)
		e.appear_delay = 0
		e.loc = at
	}
	return r
}

// For each weapon, mode, scenario and loadout, the best policy's DPS.
dps_best :: proc(sh: ^Shared, alloc := context.allocator) -> Table {
	out := make(Table, len(sh.weapons), alloc)
	for &w in out {
		for &m in w {
			for &sc in m {
				sc = make([]Best, len(sh.configs), alloc)
			}
		}
	}
	secs := f64(sh.steps) / STEP_HZ
	for j, i in sh.jobs {
		o := sh.outcomes[i]
		mode := Mode.Primary
		if j.policy.kind == .Charge {
			mode = .Charge
		} else if o.charged {
			continue
		}
		b := &out[j.weapon][mode][j.scenario][j.config]
		if dps := o.damage / secs; !b.tried || dps > b.dps {
			b^ = {true, dps, f64(o.hits) / secs, j.policy}
		}
	}
	return out
}

policy_name :: proc(p: Policy) -> string {
	switch p.kind {
	case .Tap:
		return fmt.tprintf("tap every %d", p.period)
	case .Hold:
		return "hold"
	case .Charge:
		return "charge"
	}
	return ""
}
