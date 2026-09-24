package game

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

import "dr:data"
import "dr:prefs"
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
	// Saved preferences, with this run's launch flags layered on top.
	// Headless captures use the defaults instead, so a player's own
	// settings can never change what a comparison shot shows.
	ps := Prefs_State{saved = prefs.defaults(), launch = settings}

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

	menu_shot_name := os.get_env("DR_MENU_SHOT", context.temp_allocator)
	if !headless {
		ps = prefs_state_load(settings)
	}

	// A menu capture draws into its own render texture (run_menu_shot), so
	// its window never needs to be seen.
	flags := rl.ConfigFlags{.VSYNC_HINT, .WINDOW_RESIZABLE}
	if menu_shot_name != "" {
		flags += {.WINDOW_HIDDEN}
	}
	rl.SetConfigFlags(flags)
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
	rl.SetTargetFPS(i32(step_hz)) // the interactive loop retargets per the high refresh rate setting

	renderer: Renderer
	renderer_init(&renderer, root, prefs_classic(&ps), !headless)
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
	if menu_shot_name != "" {
		run_menu_shot(&renderer, &defs, state, root, menu_shot_name, os.get_env("DR_SHOT", context.temp_allocator), &ps)
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

	// DR_SHOT=<path> renders DR_SHOT_AT steps (comma-separated) and writes a
	// PNG of each, then exits. Running the real thing is the only way to see
	// whether the compositing is right, and this makes that reviewable
	// without a desktop session.
	if shot != "" {
		// DR_SHOT_ACCENTS=<hue>,<hue> draws each player with a netplay
		// accent (flow_draw's r.accents), to check them without a session.
		accents := os.get_env("DR_SHOT_ACCENTS", context.temp_allocator)
		for field, i in strings.split(accents, ",", context.temp_allocator) {
			if hue, ok := strconv.parse_int(strings.trim_space(field)); ok && i < sim.MAX_PLAYERS {
				renderer.accents[i] = {on = true, hue = f32(prefs.hue_wrap(hue))}
			}
		}
		run_shots(&renderer, state, &particles, &blurs, &notices, playing_film ? &film : nil, shot,
			os.get_env("DR_SHOT_AT", context.temp_allocator))
		return
	}

	// Interactive: Flow owns the session lifecycle from here on (Title until
	// the player starts one, then Playing/Paused/Game_Over/Complete/Attract),
	// so state stays zeroed until flow_start_session or flow_load_demo runs.
	flow: Flow
	flow_init(&flow, root, &defs, state, &renderer, &ps)
	defer flow_destroy(&flow)

	// Every frame is drawn into this fixed 1280x960 canvas, then scaled to
	// fit the window, letterboxed -- which is what lets fullscreen (and a
	// resized window) show the whole game rather than its top-left corner.
	renderer.canvas = rl.LoadRenderTexture(SCREEN_W * WINDOW_SCALE, SCREEN_H * WINDOW_SCALE)

	// DR_NETPLAY=host or DR_NETPLAY=join:<address> jumps straight into the
	// netplay lobby already hosting/joining -- see
	// netplay_lobby_start_from_flag's comment for why (a scripted test
	// driving two instances at once, tools/netplay/loopback_check.sh).
	if netplay_flag := os.get_env("DR_NETPLAY", context.temp_allocator); netplay_flag != "" {
		netplay_lobby_init(&flow.netplay, &renderer)
		flow.mode = .Netplay_Lobby
		netplay_lobby_start_from_flag(&flow.netplay, &ps.saved, netplay_flag)
	}

	// Escape means pause/resume/back everywhere in Flow, not an instant quit
	// (raylib's own default exit key is Escape); flow.quit below is the only
	// path left that closes the window on Escape, from the title screen.
	rl.SetExitKey(.KEY_NULL)

	diagnostics: Diagnostics

	// Fixed-step: the simulation advances in slices of step_dt regardless of
	// how often the frame is actually presented, so -highrefreshrate (or a
	// slow/fast monitor, or a stall) changes how smoothly the game is shown,
	// never how fast it plays.
	step_dt := 1.0 / f64(step_hz)
	accumulator: f64 = 0
	show_debug := false

	// High refresh rate: the state as it was before the latest step, which
	// the renderer draws each frame interpolated towards the current one
	// (render.odin's interp). Copied only while the setting is on. Purely
	// presentation: nothing ever reads it back into the simulation, so it
	// cannot change gameplay, films, netplay or a checksum -- at the cost of
	// drawing up to one step (~33 ms) behind the newest state.
	interp_prev := new(sim.State)
	defer free(interp_prev)
	fps_high: Maybe(bool)
	for !rl.WindowShouldClose() && !flow.quit {
		// Preferences edits ps in place; apply whatever it holds now.
		renderer.classic = prefs_classic(&ps)
		diagnostics.enabled = prefs_diagnostics(&ps)
		renderer.textures.sfx_volume = f32(ps.saved.sfx_volume) / 100
		renderer.textures.music_volume = f32(ps.saved.music_volume) / 100
		if prefs_fullscreen(&ps) != rl.IsWindowState({.BORDERLESS_WINDOWED_MODE}) {
			rl.ToggleBorderlessWindowed()
		}
		high := prefs_high_refresh_rate(&ps)
		if applied, ok := fps_high.?; !ok || applied != high {
			fps := i32(step_hz)
			if high {
				rate := rl.GetMonitorRefreshRate(rl.GetCurrentMonitor())
				fps = rate > 0 ? rate : 60
			}
			rl.SetTargetFPS(fps)
			fps_high = high
		}
		dst := canvas_fit(renderer.canvas)
		// Mouse positions come back in canvas pixels, so every menu's
		// hit-testing (menu_mouse_pos) is unaffected by the scaling.
		rl.SetMouseOffset(-i32(dst.x), -i32(dst.y))
		rl.SetMouseScale(f32(renderer.canvas.texture.width) / dst.width, f32(renderer.canvas.texture.height) / dst.height)

		if rl.IsKeyPressed(.F1) {
			show_debug = !show_debug
		}
		if rl.IsKeyPressed(.F2) {
			renderer.shadows = !renderer.shadows
		}
		flow_handle_input(&flow, &renderer)
		accumulator += f64(rl.GetFrameTime())
		for steps := 0; accumulator >= step_dt && steps < MAX_STEPS_PER_FRAME; steps += 1 {
			was_playing := flow.mode == .Playing
			if high {
				interp_prev^ = state^ // before this step; a step that changes nothing leaves them equal
			}
			flow_step(&flow, &renderer, &particles, &blurs, &notices)
			if was_playing {
				diagnostics_note_update(&diagnostics)
			}
			accumulator -= step_dt
		}
		flow_music_update(&flow, &renderer)
		// How far the render is between the last step and the next.
		renderer.interp_prev = high ? interp_prev : nil
		renderer.interp_alpha = high ? f32(clamp(accumulator / step_dt, 0, 1)) : 1
		diagnostics_tick(&diagnostics, rl.GetFrameTime(), flow.netplay_active ? flow.netplay.rs.rollback_count : 0)

		rl.BeginTextureMode(renderer.canvas)
		rl.ClearBackground(rl.Color{0, 0, 0, 255})
		flow_draw(&flow, &renderer, &particles, &blurs, &notices, WINDOW_SCALE)
		if show_debug && state.level != nil {
			draw_debug(state, &report)
		}
		diagnostics_draw(&diagnostics, flow.netplay_active, flow.netplay.ping_ms)
		rl.EndTextureMode()

		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{0, 0, 0, 255})
		// Nearest-neighbour at a whole-number scale keeps the pixels exact
		// (the ordinary 1280x960 window is 1:1); anything else is smoothed
		// rather than drawn with uneven pixel widths.
		whole := dst.width == f32(i32(dst.width / f32(renderer.canvas.texture.width))) * f32(renderer.canvas.texture.width)
		rl.SetTextureFilter(renderer.canvas.texture, whole ? .POINT : .BILINEAR)
		src := rl.Rectangle{0, 0, f32(renderer.canvas.texture.width), -f32(renderer.canvas.texture.height)} // render textures are bottom-up
		// Premultiplied: the canvas's colour is already composited, but
		// blending left its alpha below 255 under anything translucent, and
		// ordinary alpha blending would darken those pixels a second time.
		rl.BeginBlendMode(.ALPHA_PREMULTIPLY)
		rl.DrawTexturePro(renderer.canvas.texture, src, dst, {0, 0}, 0, rl.WHITE)
		rl.EndBlendMode()
		rl.EndDrawing()
	}
}

// Where the canvas goes in the window: as large as fits without cropping,
// centred, keeping the 4:3 shape.
canvas_fit :: proc(canvas: rl.RenderTexture2D) -> rl.Rectangle {
	cw, ch := f32(canvas.texture.width), f32(canvas.texture.height)
	sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	scale := min(sw / cw, sh / ch)
	w, h := cw * scale, ch * scale
	return {f32(i32((sw - w) / 2)), f32(i32((sh - h) / 2)), w, h}
}

// One named menu screen, drawn once and exported to <path>.png. See
// docs/phase-7-faithful-menus.md's "Verification" section and
// tools/oracle/menu_shot.sh/menu_compare.sh, which drive this to compare
// against the original. Flow's Title branch (the only menu mode so far)
// returns before touching particles/blurs/notices, so nil is safe here; add
// a case as each later stage (Level Select, Credits, High Scores) lands.
run_menu_shot :: proc(r: ^Renderer, defs: ^sim.Defs, state: ^sim.State, root, name, path: string, ps: ^Prefs_State) {
	flow: Flow
	flow_init(&flow, root, defs, state, r, ps)
	// Real (empty) presentation buffers, for the cases that draw a game
	// frame behind the menu.
	particles: Particles
	particles_init(&particles)
	defer particles_destroy(&particles)
	blurs: Blurs
	blurs_init(&blurs)
	defer blurs_destroy(&blurs)
	notices: Notices
	switch name {
	case "main":
		flow.mode = .Title
	case "level_select":
		flow.pending_game_type = .Single
		flow.mode = .Level_Select
		level_select_init(&flow.level_select)
	case "main_netplay":
		// The main menu once its first update has built the links and the
		// Netplay item -- "main" above is kept exactly as the oracle
		// comparison has always seen it.
		flow.mode = .Title
		main_menu_update(&flow, r, &flow.main_menu)
	case "preferences":
		// New content, no original to compare against: a visual check.
		flow.mode = .Preferences
		preferences_init(&flow.preferences)
		preferences_update(&flow, r, &flow.preferences) // lays the buttons out
	case "paused":
		// Single-player pause menu over a level a couple of seconds in.
		flow_start_session(&flow, 0x1234_5678, .Single, 0)
		for _ in 0 ..< 60 {
			_ = sim.session_step(state, {})
		}
		flow.mode = .Paused
		flow_handle_input(&flow, r) // builds the pause menu's buttons
	case "interpolated":
		// High refresh rate interpolation's own check: a level a few
		// seconds in, drawn DR_INTERP_ALPHA (default 0.5) of the way from
		// one step to the next. 0 should match the step before, 1 the step
		// after; anything between, lie between them.
		flow_start_session(&flow, 0x1234_5678, .Single, 0)
		for _ in 0 ..< 90 {
			_ = sim.session_step(state, {})
		}
		prev := new(sim.State, context.temp_allocator)
		prev^ = state^
		_ = sim.session_step(state, {})
		flow.mode = .Playing
		r.interp_prev = prev
		r.interp_alpha = 0.5
		if a, ok := strconv.parse_f32(os.get_env("DR_INTERP_ALPHA", context.temp_allocator)); ok {
			r.interp_alpha = a
		}
	case "credits":
		flow.mode = .Credits
		credits_init(&flow.credits)
		// Skip the initial 1s settle pause and page 0's own fade-in --
		// run_menu_shot draws exactly one static frame, so start already
		// settled on page 0 at full opacity rather than a blank background.
		flow.credits.page = 0
		flow.credits.state = .Holding
	case "high_scores":
		flow.mode = .High_Scores
		high_scores_view_init(&flow.high_scores)
		// Skip the fade-in -- run_menu_shot draws exactly one static frame,
		// so start already settled at full opacity rather than mid-fade.
		flow.high_scores.state = .Holding
	case "score_entry":
		// No real gameplay session to trigger this from in a headless shot --
		// stands up a synthetic qualifying score (single player) the same way
		// flow_finish_session does, for a quick visual smoke check rather
		// than an oracle comparison (the original screen needs an actual
		// completed session with a high enough score, which isn't practical
		// to script through xdotool -- see docs/phase-7-faithful-menus.md's
		// Stage 4 notes).
		score_entry_start(&flow.score_entry, {99999, 0}, {true, false}, "Lucena")
		flow.mode = .Score_Entry
		flow.score_entry.state = .Editing
	case "netplay_lobby":
		// New content, no original to compare against (see game/netplay.odin's
		// file header) -- this is a visual smoke check of the lobby's own
		// menu screens, not an oracle:menu-shot comparison. The cases below
		// cover Netplay_Phase's visually distinct states, plus (Phase 8
		// stage 2) the host's and guest's differing views of .Connected once
		// level select is in the mix; none open a real socket
		// (netplay_lobby_init's netplay_reset already zeroed nl.have_sock)
		// -- the fields netplay_lobby_draw actually reads are set directly
		// instead, since this only ever draws once and never polls.
		flow.mode = .Netplay_Lobby
		netplay_lobby_init(&flow.netplay, r)
	case "netplay_lobby_name":
		flow.mode = .Netplay_Lobby
		netplay_lobby_init(&flow.netplay, r)
		flow.netplay.phase = .Enter_Name
		prefs.name_set(&flow.netplay.local_name, "Keristero")
		flow.netplay.local_hue = 30
	case "netplay_lobby_join":
		flow.mode = .Netplay_Lobby
		netplay_lobby_init(&flow.netplay, r)
		flow.netplay.phase = .Enter_Address
		flow.netplay.addr_len = copy(flow.netplay.addr_buf[:], "127.0.0.1")
		flow.netplay.addr_default = true
	case "netplay_lobby_connecting":
		flow.mode = .Netplay_Lobby
		netplay_lobby_init(&flow.netplay, r)
		flow.netplay.role = .Host
		flow.netplay.phase = .Connecting
	case "netplay_lobby_connected":
		flow.mode = .Netplay_Lobby
		netplay_lobby_init(&flow.netplay, r)
		flow.netplay.role = .Guest
		flow.netplay.phase = .Connected
		flow.netplay.ping_ms = 42 // sample value -- ping_ms is only ever set from a real Pong in netplay_tick_ping
		flow.netplay.remote_ready = true // local not ready yet, so the Ready button still draws beside the peer's READY
		prefs.name_set(&flow.netplay.local_name, "Keristero") // sample names, normally from each side's Hello
		prefs.name_set(&flow.netplay.peer_name, "Supercobra")
		flow.netplay.local_hue, flow.netplay.peer_hue = 30, 280
	case "netplay_lobby_connected_host":
		// Phase 8 stage 2: the host's own view -- level-select arrows above
		// an enabled Ready (highest_reached forced high enough that
		// level_index 0 reads as unlocked regardless of this machine's real
		// save file).
		flow.mode = .Netplay_Lobby
		netplay_lobby_init(&flow.netplay, r)
		flow.netplay.role = .Host
		flow.netplay.phase = .Connected
		flow.netplay.ping_ms = 17
		flow.highest_reached = 12
	case "netplay_lobby_connected_host_locked":
		// Same, but level_index parked on a level past highest_reached --
		// "NO ACCESS" in red, Ready greyed out, matching Level Select's own
		// locked-slot language (game/menu_level_select.odin).
		flow.mode = .Netplay_Lobby
		netplay_lobby_init(&flow.netplay, r)
		flow.netplay.role = .Host
		flow.netplay.phase = .Connected
		flow.netplay.ping_ms = 17
		flow.highest_reached = 1
		flow.netplay.level_index = 3
	case "diagnostics":
		flow.mode = .Netplay_Lobby
		netplay_lobby_init(&flow.netplay, r)
		flow.netplay.role = .Guest
		flow.netplay.phase = .Connected
		flow.netplay.ping_ms = 42
	case:
		fmt.eprintfln("unknown menu %v (see run_menu_shot)", name)
		os.exit(1)
	}
	// game/diagnostics.odin's overlay: this menu name doubles as its visual
	// smoke check (there's no baseline to compare against, just a look --
	// same idea as netplay_lobby_connected above). Piggybacks on the
	// connected-lobby screen since that's the one case with a ping to show;
	// run_menu_shot draws one static frame, so the numbers are hand-set, not
	// measured by diagnostics_tick.
	diag: Diagnostics
	if name == "diagnostics" {
		diag.enabled = true
		diag.updates_per_sec = 30.0
		diag.rollbacks_per_sec = 1.2
		flow.netplay_active = true
	}
	// Drawn into a render texture rather than read back from the window,
	// which is hidden (main) -- a hidden window's back buffer is not
	// guaranteed to hold anything. r.canvas lets build_frame's terrain
	// drawing return to it (resume_canvas); renderer_destroy unloads it.
	r.canvas = rl.LoadRenderTexture(SCREEN_W * WINDOW_SCALE, SCREEN_H * WINDOW_SCALE)
	rl.BeginTextureMode(r.canvas)
	rl.ClearBackground(rl.Color{0, 0, 0, 255})
	flow_draw(&flow, r, &particles, &blurs, &notices, WINDOW_SCALE)
	diagnostics_draw(&diag, flow.netplay_active, flow.netplay.ping_ms)
	rl.EndTextureMode()
	img := rl.LoadImageFromTexture(r.canvas.texture)
	rl.ImageFlipVertical(&img) // render textures are bottom-up
	// Blending leaves the texture's alpha below 255 wherever something
	// translucent was drawn; its colour is already composited, so drop it.
	rl.ImageFormat(&img, .UNCOMPRESSED_R8G8B8)
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
