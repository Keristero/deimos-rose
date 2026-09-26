package tests

// Golden behaviour: whole runs of the simulation, fingerprinted step by step
// and compared with fingerprints recorded from a known-good build. They pin
// what the simulation does -- every random draw, and the state it leaves
// after every step -- so a restructuring (docs/phase-9-ecs.md) can be shown
// to change nothing a player could see.
//
// The runs are the four shipped demos (classic play, which oracle:diff also
// checks call for call against the original) and seeded sessions with the
// extras on, which no original exists to check. All of them play on the
// committed assets tree, so they need no original game data.
//
// The fingerprint reads the state through `golden_state_hash` alone, which
// names values rather than layouts: when the state's shape changes, only
// that procedure changes, and the recorded fingerprints still apply.
//
// A run that diverges reports the first checkpoint that differs. To record
// new fingerprints after an intended change of behaviour:
//
//     DR_GOLDEN_UPDATE=1 mise run test
//
// which rewrites tests/golden/fingerprints.txt.
//
// The wide runs (golden_wide_runs_match_the_recorded_fingerprints) are
// there for coverage (mise run coverage): every level, with players that
// can die, and sessions with the mods in other combinations. Nothing checks
// them against the original, so they pin behaviour rather than prove it;
// they were recorded after the refactor, from a build whose demos matched
// the original call for call. DR_GOLDEN_WIDE_UPDATE=1 rewrites
// tests/golden/wide.txt, and leaves fingerprints.txt alone.

import "core:fmt"
import "core:log"
import vmem "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"

import "dr:data"
import "dr:plugins/easy_mode"
import "dr:plugins/loadout"
import netplay_plugin "dr:plugins/netplay"
import "dr:plugins/passives"
import "dr:sim"

GOLDEN_PATH :: "tests/golden/fingerprints.txt"
GOLDEN_EVERY :: 500 // steps between checkpoints

Golden_Run :: struct {
	name:        string,
	steps:       int,
	draws:       int,
	checkpoints: [dynamic]u64, // every GOLDEN_EVERY steps, then the last
}

@(private = "file")
Fnv :: struct {
	h: u64,
}

@(private = "file")
fnv_init :: proc() -> Fnv {
	return {0xcbf29ce484222325}
}

@(private = "file")
mix :: proc(f: ^Fnv, v: u64) {
	x := v
	for _ in 0 ..< 8 {
		f.h ~= x & 0xff
		f.h *= 0x100000001b3
		x >>= 8
	}
}

@(private = "file")
mixf :: proc(f: ^Fnv, v: f32) {
	mix(f, u64(transmute(u32)v))
}

@(private = "file")
mixb :: proc(f: ^Fnv, v: bool) {
	mix(f, v ? 1 : 0)
}

@(private = "file")
mixv :: proc(f: ^Fnv, v: sim.Vec) {
	mixf(f, v.x)
	mixf(f, v.y)
}

@(private = "file")
mixid :: proc(f: ^Fnv, v: sim.Res_ID) {
	mix(f, u64(transmute(u32)v))
}

@(private = "file")
mix_obj :: proc(f: ^Fnv, o: ^sim.Game_Object) {
	mixv(f, o.loc)
	mixv(f, o.vel)
	mixid(f, o.sprite)
	mix(f, u64(o.frame))
	mixf(f, o.visibility)
	mixf(f, o.scale)
	mixf(f, o.tint)
	mixb(f, o.glowing)
	mix(f, u64(o.glow_amount))
}

// Everything a player could tell apart, by value. The one place that knows
// where the state keeps it.
golden_state_hash :: proc(s: ^sim.State) -> u64 {
	f := fnv_init()
	mix(&f, u64(sim.single(s, sim.Clock).time))
	mix(&f, u64(sim.frame_of(s)))
	mix(&f, u64(sim.single(s, sim.Rng).next))
	mix(&f, u64(sim.single(s, sim.Level_Info).number))
	mixb(&f, sim.single(s, sim.Level_End).complete)
	mixb(&f, sim.single(s, sim.Game_Status).game_over)
	mixb(&f, netplay_plugin.paused(s))
	mix(&f, u64(sim.single(s, sim.Bgnd).view_top))
	mix(&f, u64(sim.single(s, sim.Bgnd).side_scroll))
	for p in sim.players_of(s) {
		mixb(&f, p.active)
		mix(&f, u64(p.state))
		mix_obj(&f, p.obj)
		mixf(&f, p.shields)
		mix(&f, u64(p.money))
		mix(&f, u64(p.score))
		mix(&f, u64(p.lives))
		mix(&f, u64(p.multiplier))
		mixb(&f, p.invulnerable)
		// A plugin that is off hashes as its components would start.
		levels: passives.Passive_Levels
		if st := sim.get(s.ecs, sim.player_entity(p.number), passives.Passive_State); st != nil {
			levels = st.passives
		}
		for lv in levels {
			mix(&f, u64(lv))
		}
		wh := p.weapons
		mix(&f, u64(wh.air.weapon))
		mix(&f, u64(wh.ground.weapon))
		mix(&f, u64(wh.air_powerup.state))
		mix(&f, u64(wh.ground_powerup.state))
		mixb(&f, wh.crosshair_shown)
		mixb(&f, wh.crosshair_locked)
		mixv(&f, wh.crosshair.loc)
		slots := [loadout.LOADOUT_SLOTS]i32{0 ..< loadout.LOADOUT_SLOTS = sim.NO_WEAPON}
		if ls := loadout.slots_of(s, p.number); ls != nil {
			slots = ls.loadout
		}
		for w in slots {
			mix(&f, u64(u32(w)))
		}
	}
	mixb(&f, easy_mode.reward_open(s))
	mixb(&f, loadout.loadout_open(s))
	w := sim.single(s, sim.Pool)
	for g := w.active.head; g != sim.NO_LINK; g = sim.link_of(sim.group_links(s), g).next {
		grp := sim.group_at(s, g)
		mix(&f, u64(grp.id))
		mix(&f, u64(grp.killed))
		for i := grp.entities.head; i != sim.NO_LINK; i = sim.link_of(sim.entity_links(s), i).next {
			e := sim.entity_at(s, i)
			mix(&f, u64(i))
			mix(&f, u64(e.unit))
			mix(&f, u64(e.number))
			mix(&f, u64(e.state))
			mixf(&f, e.shields)
			mixb(&f, e.deleted)
			mix(&f, u64(e.owner_player))
			mix_obj(&f, e.obj)
		}
	}
	return f.h
}

// The random draws, in order, with where each was made.
@(private = "file")
draws_hash :: proc(log: ^sim.Draw_Log) -> u64 {
	f := fnv_init()
	for d in sim.draw_log_entries(log) {
		mix(&f, u64(d.site))
		mix(&f, u64(d.kind))
		mix(&f, u64(d.a) | u64(d.b) << 32)
		mix(&f, u64(d.frame))
	}
	return f.h
}

// The shipped demo `name` (de01..de04), stepped as oracle:diff steps it.
@(private = "file")
golden_demo :: proc(defs: ^sim.Defs, name: string, allocator := context.allocator) -> (r: Golden_Run, ok: bool) {
	bytes, err := os.read_entire_file(fmt.tprintf("assets/films/%s.film", name), allocator)
	if err != nil {
		return
	}
	f, perr := data.film_parse(bytes)
	if perr != .None {
		return
	}
	film := data.film_to_sim(f)
	log := sim.Draw_Log{draws = make([]sim.Draw, 400_000, allocator)}
	s := new(sim.State, allocator)
	defer sim.destroy(s)
	sim.init(s, film.session, defs, &log)
	r = {name = name, checkpoints = make([dynamic]u64, allocator)}
	max_steps := 4 * len(film.frames) + 10_000
	for r.steps < max_steps && !sim.film_finished(s, &film) {
		sim.step(s, {}, &film)
		r.steps += 1
		if r.steps % GOLDEN_EVERY == 0 {
			append(&r.checkpoints, golden_state_hash(s))
		}
	}
	append(&r.checkpoints, golden_state_hash(s), draws_hash(&log))
	r.draws = log.count
	return r, true
}

// A session with the extras on: seeded random input for every active
// player, both kept alive so the run reaches the end-of-level screens,
// through session_step as a real game is.
Golden_Session :: struct {
	name:      string,
	level:     int, // index into defs.levels
	game_type: sim.Game_Type,
	easy:      bool,
	loadout:   bool,
	seed:      u32,
	steps:     int,
	mortal:    bool,     // players can be hit and die, as in a real game
	extra:     sim.Mods, // session plugins besides easy and loadout's
}

GOLDEN_SESSIONS := [?]Golden_Session {
	{"coop_extras_l6", 5, .Co_Op, true, true, 1234, 12_000, false, {}}, // into stage 7's loadout, the Chaingun
	{"coop_extras_l10", 9, .Co_Op, true, true, 99, 12_000, false, {}}, // stage 10's, the Discharge Beam
	{"single_easy_l1", 0, .Single, true, false, 7, 9000, false, {}}, // the reward screen after stage 1
}

@(private = "file")
golden_session :: proc(defs: ^sim.Defs, g: Golden_Session, allocator := context.allocator, scratch := context.allocator) -> Golden_Run {
	log := sim.Draw_Log{draws = make([]sim.Draw, 1_000_000, scratch)}
	s := new(sim.State, scratch)
	defer sim.destroy(s)
	session := sim.Session {
		seed      = g.seed,
		level_id  = defs.levels[g.level].id,
		game_type = g.game_type,
		mods      = sim.mods_session(sim.mods_with_deps(session_mods(g.easy, g.loadout) + g.extra)),
	}
	sim.init(s, session, defs, &log)
	// The input's own generator, apart from the state's.
	pad := sim.rand_init(g.seed ~ 0x5eed)
	r := Golden_Run{name = g.name, checkpoints = make([dynamic]u64, allocator)}
	input: sim.Frame_Input
	for r.steps < g.steps {
		// Buttons change every few steps rather than every step, so charges
		// build up and moves carry the ship somewhere.
		// On the reward and loadout screens, presses (every other step, so
		// each is a new press) of a direction or Fire_Air only: Fire_Ground
		// takes a ready back, and random play would never have both players
		// ready at once.
		screen := easy_mode.reward_open(s) || loadout.loadout_open(s)
		if screen || r.steps % 6 == 0 {
			for k in 0 ..< sim.MAX_PLAYERS {
				b := sim.Buttons{}
				for btn in sim.Button {
					if btn == .Pause || (screen && (btn == .Fire_Ground || btn == .Change_Air)) {
						continue
					}
					if sim.random_int(&pad, 0, 3, 0) == 0 {
						b += {btn}
					}
				}
				if l := loadout.loadout_of(s); l != nil && l.active && l.choosing[k] {
					b = loadout_policy(&l.boards[k])
				}
				input[k] = screen && r.steps % 2 == 1 ? {} : b
			}
		}
		// Kept in play as session_test.odin keeps its players: the flags
		// alone, every step (a new level clears invulnerable).
		for p in sim.players_of(s) {
			if !g.mortal {
				p.invulnerable_always = true
				p.invulnerable = true
			}
		}
		sim.session_step(s, input)
		r.steps += 1
		if r.steps % GOLDEN_EVERY == 0 {
			append(&r.checkpoints, golden_state_hash(s))
		}
	}
	append(&r.checkpoints, golden_state_hash(s), draws_hash(&log))
	r.draws = log.count
	return r
}

// Places every new weapon on the loadout screen, then readies: carry each
// one to the first empty cell of the loadout, else of the spares.
@(private = "file")
loadout_policy :: proc(b: ^loadout.Loadout_Board) -> sim.Buttons {
	if b.ready {
		return {}
	}
	target_row, target_col := loadout.Loadout_Row.Ready, i32(0)
	find :: proc(b: ^loadout.Loadout_Board, row: loadout.Loadout_Row, want_empty: bool) -> (i32, bool) {
		for c in 0 ..< b.width[row] {
			if (b.cells[row][c] == sim.NO_WEAPON) == want_empty {
				return c, true
			}
		}
		return 0, false
	}
	if b.holding {
		if c, ok := find(b, .Slots, true); ok {
			target_row, target_col = .Slots, c
		} else if c, ok := find(b, .Spare, true); ok {
			target_row, target_col = .Spare, c
		}
	} else if c, ok := find(b, .Fresh, false); ok {
		target_row, target_col = .Fresh, c
	}
	switch {
	case b.row < target_row:
		return {.Down}
	case b.row > target_row:
		return {.Up}
	case b.col < target_col:
		return {.Right}
	case b.col > target_col:
		return {.Left}
	}
	return {.Fire_Air}
}

@(private = "file")
golden_format :: proc(runs: []Golden_Run) -> string {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&sb, "# name steps draws checkpoint... (tests/golden_test.odin; DR_GOLDEN_UPDATE=1 rewrites)")
	for r in runs {
		fmt.sbprintf(&sb, "%s %d %d", r.name, r.steps, r.draws)
		for c in r.checkpoints {
			fmt.sbprintf(&sb, " %016x", c)
		}
		fmt.sbprintln(&sb)
	}
	return strings.to_string(sb)
}

@(private = "file")
golden_parse :: proc(text: string, allocator := context.allocator) -> map[string]Golden_Run {
	out := make(map[string]Golden_Run, allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if line == "" || line[0] == '#' {
			continue
		}
		f := strings.fields(line, allocator)
		if len(f) < 3 {
			continue
		}
		r := Golden_Run{name = f[0], checkpoints = make([dynamic]u64, allocator)}
		r.steps, _ = strconv.parse_int(f[1])
		r.draws, _ = strconv.parse_int(f[2])
		for c in f[3:] {
			v, _ := strconv.parse_u64_of_base(c, 16)
			append(&r.checkpoints, v)
		}
		out[r.name] = r
	}
	return out
}

@(test)
golden_runs_match_the_recorded_fingerprints :: proc(t: ^testing.T) {
	if !os.exists("assets/data/index.json") {
		log.info("skipped: needs the extracted assets tree")
		return
	}
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	alloc := vmem.arena_allocator(&arena)
	context.allocator = alloc // film_parse's frames, among others

	defs, _ := data.assets_defs_load("assets", alloc)
	data.extra_defs_load("assets", &defs, alloc)
	if !testing.expect(t, len(defs.levels) > 9, "the level list must load") {
		return
	}

	runs := make([dynamic]Golden_Run, alloc)
	for name in ([4]string{"de01", "de02", "de03", "de04"}) {
		r, ok := golden_demo(&defs, name, alloc)
		if testing.expectf(t, ok, "%s must load", name) {
			append(&runs, r)
		}
	}
	for g in GOLDEN_SESSIONS {
		append(&runs, golden_session(&defs, g, alloc))
	}

	golden_check(t, runs[:], GOLDEN_PATH, "DR_GOLDEN_UPDATE", alloc)
}

// Compares runs with the fingerprints recorded at `path`, or records them
// when the environment variable `update` is set.
@(private = "file")
golden_check :: proc(t: ^testing.T, runs: []Golden_Run, path, update: string, alloc := context.allocator) {
	if os.get_env(update, context.temp_allocator) != "" {
		os.make_directory("tests/golden")
		werr := os.write_entire_file(path, transmute([]u8)golden_format(runs))
		testing.expectf(t, werr == nil, "writing %s", path)
		log.infof("recorded %d golden runs in %s", len(runs), path)
		return
	}

	text, rerr := os.read_entire_file(path, alloc)
	if !testing.expectf(t, rerr == nil, "no %s: record it with %s=1", path, update) {
		return
	}
	want := golden_parse(string(text), alloc)
	for &got in runs {
		w, known := want[got.name]
		if !testing.expectf(t, known, "%s: no recorded fingerprint", got.name) {
			continue
		}
		testing.expectf(t, got.steps == w.steps, "%s: %d steps, recorded %d", got.name, got.steps, w.steps)
		testing.expectf(t, got.draws == w.draws, "%s: %d random draws, recorded %d", got.name, got.draws, w.draws)
		n := min(len(got.checkpoints), len(w.checkpoints))
		for i in 0 ..< n {
			if got.checkpoints[i] != w.checkpoints[i] {
				what := i == len(w.checkpoints) - 1 ? "the random draws" : i == len(w.checkpoints) - 2 ? "the final state" : fmt.tprintf("the state after step %d", (i + 1) * GOLDEN_EVERY)
				testing.expectf(t, false, "%s: %s first differ from the recording", got.name, what)
				break
			}
		}
	}
}

GOLDEN_WIDE_PATH :: "tests/golden/wide.txt"
GOLDEN_WIDE_STEPS :: 6000

// Every level, played by one mortal player on random input: dying, losing
// lives and the game over, on every level's units. Then co-op sessions
// with every session mod on, and the passives without Easy Mode.
@(private = "file")
golden_wide_sessions :: proc(defs: ^sim.Defs, allocator := context.allocator) -> []Golden_Session {
	out := make([dynamic]Golden_Session, allocator)
	for level in 0 ..< len(defs.levels) {
		append(&out, Golden_Session {
			name = fmt.aprintf("wide_l%d_single", level + 1, allocator = allocator),
			level = level, game_type = .Single, seed = u32(100 + level), steps = GOLDEN_WIDE_STEPS, mortal = true,
		})
	}
	for level in ([?]int{2, 5, 8, 11}) {
		append(&out, Golden_Session {
			name = fmt.aprintf("wide_l%d_coop_mods", level + 1, allocator = allocator),
			level = level, game_type = .Co_Op, easy = true, loadout = true, seed = u32(200 + level),
			steps = GOLDEN_WIDE_STEPS, mortal = true,
		})
	}
	append(&out, Golden_Session {
		name = "wide_l4_passives", level = 3, game_type = .Single, seed = 304, steps = GOLDEN_WIDE_STEPS,
		extra = {int(passives.ID)},
	})
	return out[:]
}

@(test)
golden_wide_runs_match_the_recorded_fingerprints :: proc(t: ^testing.T) {
	if !os.exists("assets/data/index.json") {
		log.info("skipped: needs the extracted assets tree")
		return
	}
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	alloc := vmem.arena_allocator(&arena)
	context.allocator = alloc

	defs, _ := data.assets_defs_load("assets", alloc)
	data.extra_defs_load("assets", &defs, alloc)
	if !testing.expect(t, len(defs.levels) == 12, "the level list must load") {
		return
	}
	runs := make([dynamic]Golden_Run, alloc)
	for g in golden_wide_sessions(&defs, alloc) {
		// Each run's draw log and state in an arena of its own.
		run_arena: vmem.Arena
		testing.expect(t, vmem.arena_init_growing(&run_arena) == nil)
		append(&runs, golden_session(&defs, g, alloc, vmem.arena_allocator(&run_arena)))
		vmem.arena_destroy(&run_arena)
	}
	golden_check(t, runs[:], GOLDEN_WIDE_PATH, "DR_GOLDEN_WIDE_UPDATE", alloc)
}

