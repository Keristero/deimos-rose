package game

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

import "dr:data"
import "dr:sim"

// The original presents a 416x480 play-field inside a 640x480 screen; the
// terrain runtime configures a 416x480x16 source view. We keep that logical
// size and let raylib scale it to the window. The remaining 224x480 strip on
// the right is the score bar panel (U_Display::GetFrontScorebarRect places it
// immediately after the play field; U_Display::Init hardcodes the screen
// itself to 640x480, not a perm float).
PLAY_W :: 416
PLAY_H :: 480
SCREEN_W :: 640
SCREEN_H :: 480

WINDOW_SCALE :: 2

// A stall (window drag, breakpoint, GC pause) must not make the simulation
// try to catch up all at once; cap how many steps one render frame can run.
MAX_STEPS_PER_FRAME :: 4

main :: proc() {
	settings := settings_parse(os.args)

	// Everything comes out of the extracted assets tree. The original
	// install is needed only to produce it, and by the oracle tooling.
	root := os.get_env("DR_ASSETS", context.temp_allocator)
	if root == "" {
		root = "assets"
	}
	defs, report := data.assets_defs_load(root)
	if len(defs.levels) == 0 {
		fmt.eprintfln("no level definitions under %v -- run `mise run assets:all`", root)
		os.exit(1)
	}

	// DR_SHOT and DR_MENU_SHOT (below) drive every headless capture --
	// oracle:shot's compare, the shots:compare task and menu_compare.sh all
	// run under xvfb-run with no PulseAudio session behind it, and nothing is
	// there to hear it either way, so skip the audio device and asset loading
	// entirely rather than let raylib log device-init failures every run.
	headless := os.get_env("DR_SHOT", context.temp_allocator) != "" ||
		os.get_env("DR_MENU_SHOT", context.temp_allocator) != ""

	rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_RESIZABLE})
	rl.InitWindow(SCREEN_W * WINDOW_SCALE, SCREEN_H * WINDOW_SCALE, "Deimos Rising")
	defer rl.CloseWindow()

	if !headless {
		rl.InitAudioDevice()
	}
	defer if !headless {
		rl.CloseAudioDevice()
	}

	// FPS_MaxRate (perm float 0x20) is 30.0 in the shipped data:
	// G_GameInterface::Draw steps once, draws, then busy-waits on FPS_Delay
	// (0x21, in ~16.66ms ticks) before the next step. The original runs at
	// 30 FPS, not 60 -- an unconditional SetTargetFPS(60) here previously
	// ran the whole simulation at double speed.
	step_hz := defs.perm_floats[0x20]
	if settings.high_refresh_rate {
		rate := rl.GetMonitorRefreshRate(rl.GetCurrentMonitor())
		rl.SetTargetFPS(rate > 0 ? rate : 60)
	} else {
		rl.SetTargetFPS(i32(step_hz))
	}

	renderer: Renderer
	renderer_init(&renderer, root, settings.classic, !headless)
	defer renderer_destroy(&renderer)

	particles: Particles
	particles_init(&particles)
	defer particles_destroy(&particles)

	blurs: Blurs
	blurs_init(&blurs)
	defer blurs_destroy(&blurs)

	notices: Notices

	state := new(sim.State)
	defer free(state)

	// DR_MENU_SHOT=<name> renders one named menu screen and writes a single
	// PNG to DR_SHOT, then exits -- the menu equivalent of DR_SHOT below, for
	// tools/oracle/menu_compare.sh. A menu has no simulation to step, so
	// there is exactly one frame to capture, not a series of them.
	if menu_shot := os.get_env("DR_MENU_SHOT", context.temp_allocator); menu_shot != "" {
		run_menu_shot(&renderer, &defs, state, root, menu_shot, os.get_env("DR_SHOT", context.temp_allocator))
		return
	}

	// DR_FILM=de01 replays a shipped demo instead of taking input, so a
	// screenshot can be compared with the original stopped at the same step.
	film: sim.Film
	playing_film := false
	if name := os.get_env("DR_FILM", context.temp_allocator); name != "" {
		bytes, ferr := os.read_entire_file(fmt.tprintf("%s/films/%s.film", root, name), context.allocator)
		f, perr := data.film_parse(bytes)
		if ferr != nil || perr != .None {
			fmt.eprintfln("cannot read film %v: %v/%v", name, ferr, perr)
			os.exit(1)
		}
		film = data.film_to_sim(f)
		playing_film = true
		sim.init(state, film.session, &defs)
	}

	shot := os.get_env("DR_SHOT", context.temp_allocator)
	if shot != "" && !playing_film {
		// DR_SHOT with no DR_FILM shoots the same fixed-seed default session
		// this always started with, before Flow made a fresh interactive run
		// defer sim.init to the title screen -- preserved so existing
		// DR_SHOT-only invocations keep seeing the same frames.
		level := defs.levels[0].id // play order: Lucena is level 1
		sim.init(state, sim.Session{seed = 0x1234_5678, level_id = level, game_type = .Single}, &defs)
	}

	if !headless && state.level != nil {
		if music, ok := music_track(&renderer.textures, state.level.id); ok {
			rl.PlayMusicStream(music)
		}
	}

	// DR_SHOT=<path> renders DR_SHOT_AT steps (comma-separated) and writes a
	// PNG of each, then exits. Running the real thing is the only way to see
	// whether the compositing is right, and this makes that reviewable
	// without a desktop session.
	if shot != "" {
		run_shots(&renderer, state, &particles, &blurs, &notices, playing_film ? &film : nil, shot,
			os.get_env("DR_SHOT_AT", context.temp_allocator))
		return
	}

	// Interactive: Flow owns the session lifecycle from here on (Title until
	// the player starts one, then Playing/Paused/Game_Over/Complete/Attract),
	// so state stays zeroed until flow_start_session or flow_load_demo runs.
	flow: Flow
	flow_init(&flow, root, &defs, state, &renderer)
	defer flow_destroy(&flow)

	// Escape means pause/resume/back everywhere in Flow, not an instant quit
	// (raylib's own default exit key is Escape); flow.quit below is the only
	// path left that closes the window on Escape, from the title screen.
	rl.SetExitKey(.KEY_NULL)

	// Fixed-step: the simulation advances in slices of step_dt regardless of
	// how often the frame is actually presented, so -highrefreshrate (or a
	// slow/fast monitor, or a stall) changes how smoothly the game is shown,
	// never how fast it plays.
	step_dt := 1.0 / f64(step_hz)
	accumulator: f64 = 0
	show_debug := false
	for !rl.WindowShouldClose() && !flow.quit {
		if rl.IsKeyPressed(.F1) {
			show_debug = !show_debug
		}
		if rl.IsKeyPressed(.F2) {
			renderer.shadows = !renderer.shadows
		}
		flow_handle_input(&flow, &renderer)
		accumulator += f64(rl.GetFrameTime())
		for steps := 0; accumulator >= step_dt && steps < MAX_STEPS_PER_FRAME; steps += 1 {
			flow_step(&flow, &renderer, &particles, &blurs, &notices)
			accumulator -= step_dt
		}
		if state.level != nil {
			if music, ok := music_track(&renderer.textures, state.level.id); ok {
				rl.UpdateMusicStream(music)
			}
		}

		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{0, 0, 0, 255})
		flow_draw(&flow, &renderer, &particles, &blurs, &notices, WINDOW_SCALE)
		if show_debug && state.level != nil {
			draw_debug(state, &report)
		}
		rl.EndDrawing()
	}
}

// One named menu screen, drawn once and exported to <path>.png. See
// docs/phase-7-faithful-menus.md's "Verification" section and
// tools/oracle/menu_shot.sh/menu_compare.sh, which drive this to compare
// against the original. Flow's Title branch (the only menu mode so far)
// returns before touching particles/blurs/notices, so nil is safe here; add
// a case as each later stage (Level Select, Credits, High Scores) lands.
run_menu_shot :: proc(r: ^Renderer, defs: ^sim.Defs, state: ^sim.State, root, name, path: string) {
	flow: Flow
	flow_init(&flow, root, defs, state, r)
	switch name {
	case "main":
		flow.mode = .Title
	case "level_select":
		flow.pending_game_type = .Single
		flow.mode = .Level_Select
		level_select_init(&flow.level_select)
	case "credits":
		flow.mode = .Credits
		credits_init(&flow.credits)
		// Skip the initial 1s settle pause and page 0's own fade-in --
		// run_menu_shot draws exactly one static frame, so start already
		// settled on page 0 at full opacity rather than a blank background.
		flow.credits.page = 0
		flow.credits.state = .Holding
	case:
		fmt.eprintfln("unknown menu %v (see run_menu_shot)", name)
		os.exit(1)
	}
	rl.BeginDrawing()
	rl.ClearBackground(rl.Color{0, 0, 0, 255})
	flow_draw(&flow, r, nil, nil, nil, WINDOW_SCALE)
	rl.EndDrawing()
	img := rl.LoadImageFromScreen()
	out := fmt.ctprintf("%s.png", path)
	rl.ExportImage(img, out)
	rl.UnloadImage(img)
	fmt.printfln("wrote %s", out)
}

// Steps the simulation, capturing the frame at each requested step.
run_shots :: proc(r: ^Renderer, s: ^sim.State, particles: ^Particles, blurs: ^Blurs, notices: ^Notices, film: ^sim.Film, path, at: string) {
	steps := make([dynamic]int, context.temp_allocator)
	rest := at == "" ? "120" : at
	for field in strings.split_iterator(&rest, ",") {
		if v, ok := strconv.parse_int(strings.trim_space(field)); ok {
			append(&steps, v)
		}
	}
	slice.sort(steps[:])
	last := len(steps) == 0 ? 0 : steps[len(steps) - 1]
	next := 0
	dump := os.get_env("DR_DUMP", context.temp_allocator) != ""
	for i in 0 ..= last {
		r.dump = dump && next < len(steps) && steps[next] == i
		if r.dump {
			fmt.printfln("step %v draw list:", i)
		}
		build_frame(r, s, blurs, notices)
		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{0, 0, 0, 255})
		present(r, s, particles, WINDOW_SCALE)
		rl.EndDrawing()
		if r.dump {
			r.dump = false
		}
		for next < len(steps) && steps[next] == i {
			img := rl.LoadImageFromScreen()
			name := fmt.ctprintf("%s-%04d.png", path, i)
			rl.ExportImage(img, name)
			rl.UnloadImage(img)
			fmt.printfln("wrote %s  (step %v, %v entities)", name, i, s.world.used_count)
			next += 1
		}
		sim.step(s, {}, film)
		particles_step(particles, s)
		blurs_step(blurs, s)
		notices_step(notices, s)
		sounds_step(&r.textures, s)
	}
}

draw_debug :: proc(s: ^sim.State, report: ^data.Defs_Report) {
	rl.DrawText(
		fmt.ctprintf(
			"frame %v  time %v  entities %v  scroll %v\nplayer shields %.0f lives %v score %v\ndefs: %v units %v sprites %v levels",
			s.frame, s.time, s.world.used_count, s.bgnd.view_top,
			s.players[0].shields, s.players[0].lives, s.players[0].score,
			report.units, report.sprites, report.levels,
		),
		8, 8, 14, rl.Color{150, 230, 150, 255},
	)
	for used, i in s.world.entity_used {
		if !used {
			continue
		}
		b := sim.object_bounds(&s.world.entities[i].obj)
		rl.DrawRectangleLines((b.left + VIEW_X) * WINDOW_SCALE, b.top * WINDOW_SCALE,
			(b.right - b.left) * WINDOW_SCALE, (b.bottom - b.top) * WINDOW_SCALE,
			rl.Color{220, 170, 90, 120})
	}
	b := sim.object_bounds(&s.players[0].obj)
	rl.DrawRectangleLines((b.left + VIEW_X) * WINDOW_SCALE, b.top * WINDOW_SCALE,
		(b.right - b.left) * WINDOW_SCALE, (b.bottom - b.top) * WINDOW_SCALE,
		rl.Color{120, 200, 255, 160})
}

// Presentation-side input capture. The simulation never reads a device.
gather_input :: proc() -> sim.Frame_Input {
	b: sim.Buttons
	if rl.IsKeyDown(.LEFT) || rl.IsKeyDown(.A) {
		b += {.Left}
	}
	if rl.IsKeyDown(.RIGHT) || rl.IsKeyDown(.D) {
		b += {.Right}
	}
	if rl.IsKeyDown(.UP) || rl.IsKeyDown(.W) {
		b += {.Up}
	}
	if rl.IsKeyDown(.DOWN) || rl.IsKeyDown(.S) {
		b += {.Down}
	}
	if rl.IsKeyDown(.SPACE) {
		b += {.Fire_Air}
	}
	if rl.IsKeyDown(.LEFT_CONTROL) {
		b += {.Fire_Ground}
	}
	if rl.IsKeyPressed(.LEFT_SHIFT) {
		b += {.Change_Air}
	}
	return sim.Frame_Input{b, {}}
}
